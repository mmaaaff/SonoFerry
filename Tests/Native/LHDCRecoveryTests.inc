// Included by MediaTransport's offline self-test. No audio device or Bluetooth.
static DirectMediaProbe *RecoveryProbeAt(unsigned rate, unsigned bitrate) {
    DirectMediaProbe *probe = [DirectMediaProbe new];
    probe.pcmFD = -1;
    LDACProfile profile;
    if (!SelectProfile(rate == 192000 ? 96000 : rate, @"low", &profile)) return nil;
    profile.sampleRate = rate;
    if (!ConfigureBuffering(&profile, 5000, 250)) return nil;
    profile.bitrateKbps = bitrate;
    probe.profile = profile;
    probe.pcmRing = calloc(1, profile.capacityBytes);
    probe.lhdcEncoder = calloc(1, sizeof(MacLHDC));
    if (!probe.pcmRing || !probe.lhdcEncoder || !MacLHDCOpen(probe.lhdcEncoder, rate, 24, bitrate, 64, 1000, 679, 123)) return nil;
    probe.pcmContinuous = YES; probe.pcmStarted = YES;
    PrepareLHDCRecovery(probe, MonotonicTime());
    return probe;
}

static DirectMediaProbe *RecoveryProbe(unsigned bitrate) { return RecoveryProbeAt(48000, bitrate); }

static BOOL ReplayLHDCStall(unsigned bitrate) {
    DirectMediaProbe *probe = RecoveryProbe(bitrate);
    if (!probe) return NO;
    MacLHDC *codec = probe.lhdcEncoder;
    double start = MonotonicTime(), now = start;
    PrepareLHDCRecovery(probe, start);
    probe.pcmBytes = probe.profile.prefillBytes;
    uint64_t produced = 0, packets = 0, previousEnd = 0;
    unsigned selected = codec->index;
    uint8_t packet[8206]; float pcm[1920] = {0};
    for (unsigned cycle = 0; cycle < 40000; cycle++) {
        double due = LHDCFrameDue(codec, start);
        now = fmax(now, due);
        uint64_t total = (uint64_t)((now - start) * codec->rate);
        probe.pcmBytes += (total - produced) * 8; produced = total;
        // Storage must accommodate the entire configured grace period.
        if (probe.pcmBytes > probe.profile.capacityBytes) return NO;
        if (!RecoverLHDCPCM(probe, start, now)) return NO;
        if (probe.pcmBytes < codec->block * 8) return NO;
        probe.pcmHead = (probe.pcmHead + codec->block * 8) % probe.profile.capacityBytes;
        probe.pcmBytes -= codec->block * 8;
        size_t length = 0; unsigned actual = 0;
        uint64_t expectedTimestamp = codec->emitted + codec->skipped;
        if (!MacLHDCEncode(codec, pcm, packet, sizeof(packet), &length, &actual) || !length ||
            codec->index != selected || length > 679 || actual < bitrate - 5 || actual > bitrate + 5) return NO;
        uint32_t ts = (uint32_t)packet[4]<<24 | (uint32_t)packet[5]<<16 | (uint32_t)packet[6]<<8 | packet[7];
        if (ts != expectedTimestamp || ts < previousEnd || ((unsigned)packet[2]<<8 | packet[3]) != (uint16_t)packets) return NO;
        previousEnd = ts + (packet[12] >> 2) * codec->block; packets++;
        double elapsed = now - start;
        // Replay a healthy stream, then a 10-second burst of slow socket drains
        // like the user's 143–153 s incident, then a healthy stream again.
        now += elapsed >= 143 && elapsed < 153 ? 0.0058 + (packets % 80 == 0 ? 0.012 : 0) : 0.0014;
        if (elapsed >= 170) {
            BOOL passed = !probe.failed && codec->skipped > 0 &&
                codec->skipped == probe.pcmSkippedBytes / 8 && probe.pcmBytes < probe.profile.prefillBytes + codec->block * 8 &&
                now - LHDCFrameDue(codec, start) < 0.01;
            printf("LHDC_STALL_REPLAY target=%u simulatedSeconds=170 packets=%llu skippedFrames=%llu result=%s\n",
                   bitrate, packets, codec->skipped, passed ? "PASS" : "FAIL");
            return passed;
        }
    }
    return NO;
}

// Actual encoder and PCM accounting under repeatable short stalls. At 900 kbps
// each packet holds one block. Compare the old 100 ms trigger against the new
// catch-up duration policy, then require the uncut stream to catch up at unchanged bitrate.
static BOOL ReplayLHDCJitter(unsigned rate, BOOL oldPolicy) {
    DirectMediaProbe *probe = RecoveryProbeAt(rate, 900);
    if (!probe) return NO;
    MacLHDC *codec = probe.lhdcEncoder;
    double start = MonotonicTime(), now = start;
    PrepareLHDCRecovery(probe, start);
    if (oldPolicy) probe.pcmReserveBytes = probe.profile.prefillBytes;
    probe.pcmBytes = probe.profile.prefillBytes;
    uint64_t produced = 0, packets = 0, previousEnd = 0;
    uint8_t packet[8206]; float pcm[1920] = {0};
    unsigned selected = codec->index;
    for (unsigned cycle = 0; cycle < 5000; cycle++) {
        now = fmax(now, LHDCFrameDue(codec, start));
        uint64_t total = (uint64_t)((now - start) * rate);
        probe.pcmBytes += (total - produced) * 8; produced = total;
        if (probe.pcmBytes > probe.profile.capacityBytes) return NO;
        if (oldPolicy) {
            probe.pcmCanSkip = codec->consumed == codec->emitted;
            double late = now - LHDCFrameDue(codec, start);
            if (late >= 0.1) [probe discardPCMFrames:(uint64_t)fmin(late * rate, rate)];
        } else if (!RecoverLHDCPCM(probe, start, now)) return NO;
        if (probe.pcmBytes < codec->block * 8) return NO;
        probe.pcmHead = (probe.pcmHead + codec->block * 8) % probe.profile.capacityBytes;
        probe.pcmBytes -= codec->block * 8;
        size_t length = 0; unsigned actual = 0;
        if (!MacLHDCEncode(codec, pcm, packet, sizeof(packet), &length, &actual) || !length ||
            codec->index != selected || length > 679 || actual < 895 || actual > 905) return NO;
        uint32_t ts = (uint32_t)packet[4]<<24 | (uint32_t)packet[5]<<16 | (uint32_t)packet[6]<<8 | packet[7];
        if ((oldPolicy ? ts < previousEnd : ts != previousEnd) ||
            ((unsigned)packet[2]<<8 | packet[3]) != (uint16_t)packets) return NO;
        previousEnd = ts + (packet[12] >> 2) * codec->block; packets++;
        double elapsed = now - start;
        // Six 220 ms episodes with 20 ms socket drains instead of healthy 1.4 ms.
        // The receiver's actual buffering is unknown; we assert sender behavior.
        now += elapsed >= 2 && elapsed < 14 && fmod(elapsed, 2) < 0.22 ? 0.020 : 0.0014;
        if (elapsed >= 16) {
            BOOL passed = !probe.failed && (oldPolicy ? codec->skipped > 0 : codec->skipped == 0) &&
                probe.pcmBytes < probe.profile.prefillBytes + codec->block * 8 && now - LHDCFrameDue(codec, start) < 0.01;
            printf("LHDC_JITTER_REPLAY rate=%u policy=%s simulatedSeconds=16 skippedFrames=%llu result=%s\n",
                   rate, oldPolicy ? "0.1.4" : "catchup-duration", codec->skipped, passed ? "PASS" : "FAIL");
            return passed;
        }
    }
    return NO;
}

// Shared timing is exercised without real sleeps or Bluetooth access.
static BOOL CatchupTimingChecks(void) {
    CatchupState state = {0};
    BOOL passed = YES;
    ObserveCatchup(&state, 10, 10, YES); passed &= !state.active;
    ObserveCatchup(&state, 11, 10, YES); passed &= state.active && state.elapsed == 0;
    ObserveCatchup(&state, 15.999, 11, YES); passed &= fabs(state.elapsed - 4.999) < 1e-6;
    ObserveCatchup(&state, 16, 12, YES); passed &= state.elapsed == 5;
    ObserveCatchup(&state, 17, 17.001, YES); passed &= !state.active;
    ObserveCatchup(&state, 18, 17, YES); passed &= state.active && state.elapsed == 0;
    ObserveCatchup(&state, 19, 17, NO); passed &= !state.active;
    ObserveCatchup(&state, 20, 19, YES);
    ObserveCatchup(&state, 19.5, 19, YES); passed &= !state.active;
    // Healthy scheduling repeatedly arrives slightly late, then has to wait for
    // the next packet. None of those separate episodes accumulates five seconds.
    for (unsigned i = 0; i < 20000; i++) {
        double due = i * 0.005;
        ObserveCatchup(&state, due + 0.0003, due, YES);
        ObserveCatchup(&state, due + 0.0017, due + 0.005, YES);
        passed &= !state.active;
    }
    printf("CATCHUP_TIMING_CHECK continuous, reset, disabled, scheduler jitter=%s\n", passed ? "PASS" : "FAIL");
    return passed;
}

static BOOL LHDCRecoveryPolicyChecks(unsigned rate) {
    DirectMediaProbe *probe = RecoveryProbeAt(rate, 900);
    if (!probe) return NO;
    MacLHDC *codec = probe.lhdcEncoder;
    NSUInteger perSecond = rate * 8;
    BOOL passed = YES;
    // Even a 2-second backlog cannot bypass the time limit.
    probe.pcmBytes = perSecond * 2;
    passed &= RecoverLHDCPCM(probe, 0, 10) && codec->skipped == 0;
    passed &= RecoverLHDCPCM(probe, 0, 14.999) && codec->skipped == 0;
    passed &= RecoverLHDCPCM(probe, 0, 15) && codec->skipped > 0;
    passed &= probe.pcmBytes >= probe.profile.prefillBytes && probe.pcmBytes < probe.profile.prefillBytes + codec->block * 8;
    passed &= !probe.catchup.active;
    uint64_t skipped = codec->skipped;
    // Another recovery requires a new full interval, even if still behind.
    probe.pcmBytes = perSecond * 6 / 10;
    passed &= RecoverLHDCPCM(probe, 0, 15.01) && codec->skipped == skipped;
    passed &= RecoverLHDCPCM(probe, 0, 20.009) && codec->skipped == skipped;
    passed &= RecoverLHDCPCM(probe, 0, 20.01) && codec->skipped > skipped;
    skipped = codec->skipped;
    // Separated episodes are never added together.
    probe.pcmBytes = perSecond;
    passed &= RecoverLHDCPCM(probe, 0, 21) && codec->skipped == skipped;
    passed &= RecoverLHDCPCM(probe, 0, 25.9) && codec->skipped == skipped;
    passed &= RecoverLHDCPCM(probe, 30, 30) && !probe.catchup.active;
    passed &= RecoverLHDCPCM(probe, 0, 31) && codec->skipped == skipped;
    passed &= RecoverLHDCPCM(probe, 0, 35.9) && codec->skipped == skipped;
    // Finite playback, stopping and capture completion suppress recovery.
    probe.pcmContinuous = NO;
    passed &= RecoverLHDCPCM(probe, 0, 40) && codec->skipped == skipped && !probe.catchup.active;
    probe.pcmContinuous = YES; probe.stopRequested = YES;
    passed &= RecoverLHDCPCM(probe, 0, 50) && codec->skipped == skipped;
    probe.stopRequested = NO; probe.pcmComplete = YES;
    passed &= RecoverLHDCPCM(probe, 0, 60) && codec->skipped == skipped;
    printf("LHDC_CATCHUP_CHECK rate=%u grace, recovery, retained prefill, reset, stop and finite=%s\n", rate, passed ? "PASS" : "FAIL");
    return passed;
}

static BOOL BufferingRangeChecks(void) {
    BOOL passed = YES;
    for (unsigned r = 0; r < 5; r++) {
        unsigned rate = (unsigned[]){44100,48000,88200,96000,192000}[r];
        for (unsigned t = 0; t < 3; t++) for (unsigned p = 0; p < 3; p++) {
            unsigned limit = (unsigned[]){100,5000,15000}[t], prefill = (unsigned[]){10,250,1000}[p];
            LDACProfile profile = {.sampleRate = rate};
            passed &= ConfigureBuffering(&profile, limit, prefill);
            passed &= fabs(profile.catchupLimit - limit / 1000.0) < 1e-9;
            passed &= profile.prefillBytes / 8 == ((uint64_t)rate * prefill + 999) / 1000;
            passed &= profile.capacityBytes % PCMBlockBytes == 0;
            // A completely stalled sender still fits all PCM through the grace
            // period and the additional one-second transport failure timeout.
            passed &= profile.capacityBytes >= ((uint64_t)rate * (prefill + limit + 1000) + 999) / 1000 * 8;
            CatchupState state = {0};
            ObserveCatchup(&state, 1, 0, YES);
            ObserveCatchup(&state, 1 + profile.catchupLimit, 0, YES);
            passed &= state.elapsed + 1e-9 >= profile.catchupLimit;
            for (unsigned block = 128; block <= 960; block = block == 128 ? 240 : block * 2) {
                NSUInteger buffered = profile.prefillBytes + rate * 8;
                NSUInteger dropped = PCMSkipAlignedBytes(buffered, profile.prefillBytes, UINT64_MAX, block);
                passed &= buffered - dropped >= profile.prefillBytes && buffered - dropped < profile.prefillBytes + block * 8;
            }
        }
    }
    LDACProfile profile = {.sampleRate = 48000};
    passed &= !ConfigureBuffering(&profile, 99, 250) && !ConfigureBuffering(&profile, 101, 250) &&
              !ConfigureBuffering(&profile, 15100, 250) && !ConfigureBuffering(&profile, 5000, 9) && !ConfigureBuffering(&profile, 5000, 1001);
    printf("BUFFERING_RANGE_CHECK all rates, extrema, storage, codec alignment, invalid ranges=%s\n", passed ? "PASS" : "FAIL");
    return passed;
}

static BOOL LiveBufferingChecks(void) {
    BOOL passed = YES;
    for (unsigned i = 0; i < 4; i++) {
        unsigned rate = (unsigned[]){44100,48000,96000,192000}[i];
        DirectMediaProbe *probe = RecoveryProbeAt(rate, 900);
        if (!probe) return NO;
        uint8_t *ring = probe.pcmRing;
        NSUInteger capacity = probe.profile.capacityBytes;
        probe.pcmBytes = rate * 8 * 2;
        probe.pcmHead = capacity - 128 * 8;
        probe.catchup = (CatchupState){.active=YES,.since=1,.elapsed=4.99};
        NSString *request = @"buffering 12345678-1234-1234-1234-123456789ABC 100 10";
        passed &= ApplyLiveBuffering(probe, request);
        passed &= probe.pcmRing == ring && probe.profile.capacityBytes == capacity &&
                  probe.pcmBytes == rate * 8 * 2 && probe.pcmHead == capacity - 128 * 8 &&
                  probe.pcmSkippedBytes == 0 && !probe.catchup.active;
        passed &= probe.profile.catchupLimit == 0.1 && probe.pcmReserveBytes == ((rate + 99) / 100) * 8;
        passed &= RecoverLHDCPCM(probe, 0, 10) && probe.pcmSkippedBytes == 0;
        passed &= RecoverLHDCPCM(probe, 0, 10.099) && probe.pcmSkippedBytes == 0;
        passed &= RecoverLHDCPCM(probe, 0, 10.1) && probe.pcmSkippedBytes > 0;
        passed &= probe.pcmBytes >= probe.pcmReserveBytes && probe.pcmBytes < probe.pcmReserveBytes + probe.lhdcEncoder->block * 8;
        uint64_t skipped = probe.pcmSkippedBytes;
        NSUInteger retained = probe.pcmBytes;
        passed &= ApplyLiveBuffering(probe, @"buffering 12345678-1234-1234-1234-123456789ABC 15000 1000");
        passed &= probe.profile.catchupLimit == 15 && probe.pcmReserveBytes == rate * 8 &&
                  probe.pcmBytes == retained && probe.pcmSkippedBytes == skipped && probe.pcmRing == ring;
        passed &= !ApplyLiveBuffering(probe, @"buffering invalid 5000 250") &&
                  !ApplyLiveBuffering(probe, @"buffering 12345678-1234-1234-1234-123456789ABC 101 250") &&
                  !ApplyLiveBuffering(probe, @"buffering 12345678-1234-1234-1234-123456789ABC 5000 1001");
        passed &= probe.profile.catchupLimit == 15 && probe.pcmReserveBytes == rate * 8;
        probe.stopRequested = YES;
        passed &= ApplyLiveBuffering(probe, request) && probe.profile.catchupLimit == 15;
    }
    printf("LIVE_BUFFERING_CHECK no allocation/drop, preserved ring, timer reset, extrema, invalid commands and stop wins=%s\n", passed ? "PASS" : "FAIL");
    return passed;
}

static BOOL LHDCRecoveryChecks(void) {
    BOOL passed = CatchupTimingChecks() && BufferingRangeChecks() && LiveBufferingChecks() && ReplayLHDCStall(900) && ReplayLHDCStall(1000);
    for (unsigned i = 0; i < 4; i++) {
        unsigned rate = (unsigned[]){44100,48000,96000,192000}[i];
        passed &= ReplayLHDCJitter(rate, YES) && ReplayLHDCJitter(rate, NO) && LHDCRecoveryPolicyChecks(rate);
    }
    DirectMediaProbe *probe = RecoveryProbe(400);
    if (!probe) return NO;
    MacLHDC *codec = probe.lhdcEncoder;
    uint8_t packet[8206]; float pcm[1920] = {0}; size_t length = 0; unsigned bitrate = 0;
    passed &= MacLHDCEncode(codec, pcm, packet, sizeof(packet), &length, &bitrate) && !length;
    passed &= !MacLHDCDiscontinuity(codec, codec->block); // A queued frame must not be dropped or retimestamped.
    int pipeFD[2];
    if (pipe(pipeFD)) return NO;
    probe.pcmFD = pipeFD[0]; probe.pcmActive = YES; probe.pcmCanSkip = NO;
    if (fcntl(probe.pcmFD, F_SETFL, O_NONBLOCK)) { close(pipeFD[1]); return NO; }
    probe.pcmBytes = probe.profile.capacityBytes;
    uint8_t partial[] = {0,1,2,3,4,5,6};
    passed &= write(pipeFD[1], partial, sizeof(partial)) == sizeof(partial);
    double now = MonotonicTime();
    passed &= RecoverLHDCPCM(probe, now - 1, now);
    passed &= RecoverLHDCPCM(probe, now - 1, now + 5); // Timer expires with a queued codec frame.
    passed &= codec->skipped == 0 && probe.catchup.elapsed >= 5;
    passed &= !probe.failed && probe.pcmReadBytes == 0 && probe.pcmBytes == probe.profile.capacityBytes;
    passed &= MacLHDCEncode(codec, pcm, packet, sizeof(packet), &length, &bitrate) && length;
    probe.pcmCanSkip = YES;
    [probe pollPCM];
    passed &= codec->skipped == 0 && probe.pcmReadBytes == 0; // Polling alone cannot discard audio.
    passed &= RecoverLHDCPCM(probe, now - 1, now + 5.01);
    [probe pollPCM];
    passed &= !probe.failed && probe.pcmReadBytes == 7 && probe.pcmBytes % 8 == 7;
    passed &= codec->skipped > 0 && codec->skipped % codec->block == 0 && probe.pcmHead % 8 == 0;
    passed &= probe.pcmBytes + probe.pcmSkippedBytes == probe.profile.capacityBytes + 7;
    // A later byte must finish the same stereo PCM frame, without losing the seven bytes above.
    uint8_t last = 7;
    passed &= write(pipeFD[1], &last, 1) == 1;
    [probe pollPCM];
    passed &= probe.pcmBytes % 8 == 0;
    for (unsigned i = 0; i < 8; i++) passed &= probe.pcmRing[(probe.pcmHead + probe.pcmBytes - 8 + i) % probe.profile.capacityBytes] == i;
    probe.pcmComplete = YES;
    close(pipeFD[1]); [probe pollPCM];
    passed &= probe.pcmEnded && !probe.failed;

    printf("LHDC_RECOVERY_CHECK timer, codec queue, partial PCM frames, RTP continuity=%s\n", passed ? "PASS" : "FAIL");
    return passed;
}
