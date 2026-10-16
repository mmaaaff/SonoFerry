// Included in MediaTransport.m: codec-specific paced sender, sharing channel ownership.
#include "SenderWait.h"
#include "SenderStatistics.h"

static void ReportLHDCWindow(SenderStatistics *s, double now, double pending, BOOL force) {
    SenderStatisticsPending(s, pending);
    if (!force && now - s->started < 1) return;
    printf("SENDER_WINDOW codec=lhdcV5 windowSeconds=%.6f windowPackets=%llu windowBytes=%llu encodeBlocks=%llu packetBytesMax=%u encodeMaxMs=%.6f scheduleLateMaxMs=%.6f drainMaxMs=%.6f drainMeanMs=%.6f drainOver8ms=%llu drainOver50ms=%llu drainPendingMs=%.6f sessionDrainMaxMs=%.6f sessionDrainOver8ms=%llu sessionDrainOver50ms=%llu waitCalls=%llu waitTimeouts=%llu\n",
           now-s->started, s->packets, s->bytes, s->blocks, s->packetMax, s->encodeMax*1000,
           s->scheduleMax*1000, s->drainMax*1000, s->packets ? s->drainTotal*1000/s->packets : 0,
           s->over8, s->over50, pending*1000, s->sessionDrainMax*1000, s->sessionOver8, s->sessionOver50,
           s->waits, s->timeouts);
    SenderStatisticsReset(s, now);
}

static int WaitLHDC(SenderWait *waiter, SenderStatistics *stats, BOOL draining, BOOL needsPCM, double seconds) {
    stats->waits++;
    int result=SenderWaitOnce(waiter, draining, needsPCM, seconds);
    if (result == SenderWakeTimer) stats->timeouts++;
    if (result < 0) printf("ENCODER_FAILED codec=lhdcV5 reason=sender-wait errno=%d\n", errno);
    return result;
}

static void PrepareLHDCRecovery(DirectMediaProbe *probe, double start) {
    (void)start;
    probe.pcmReserveBytes = probe.profile.prefillBytes;
    probe.catchup = (CatchupState){0};
}

static double LHDCFrameDue(MacLHDC *codec, double start) {
    return start + ((double)codec->consumed + codec->skipped) / codec->rate;
}

static BOOL RecoverLHDCPCM(DirectMediaProbe *probe, double start, double now) {
    MacLHDC *codec = probe.lhdcEncoder;
    probe.pcmCanSkip = probe.pcmContinuous && codec->consumed == codec->emitted && !probe.stopRequested;
    [probe pollPCM];
    if (probe.failed) return NO;
    [probe recoverCatchupAt:now due:LHDCFrameDue(codec, start)];
    return !probe.failed;
}

static BOOL FeedLHDC(DirectMediaProbe *probe, CBL2CAPChannel *owned, double gain, uint32_t seconds) {
    MacLHDC *codec = probe.lhdcEncoder;
    probe.pcmStarted = YES; probe.pcmContinuous = seconds == 0; probe.pcmCanSkip = NO;
    probe.gain = gain; probe.targetGain = gain; probe.gainAckReady = NO;
    MacLHDCGain(codec, gain);
    int fd = owned.socketFD, flags = -1, queue = -1, oldLow = 0, oldNoPipe = 0;
    BOOL configured = NO, success = NO;
    unsigned long sent = 0, drained = 0, totalBytes = 0;
    double start = MonotonicTime(), progress = start + 1, stableSince = start, lastAdjustment = start;
    PrepareLHDCRecovery(probe, start);
    SenderStatistics statistics = {.started=start};
    SenderWait waiter;
    double pendingSince = 0;
    unsigned previousBitrate = 0;
    uint8_t packet[8206]; float pcm[1920];
    id activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"LHDC V5 streaming"];
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    do {
        int socketType = 0;
        if (!ReadOption(fd, SO_TYPE, &socketType) || socketType != SOCK_STREAM ||
            !ReadOption(fd, SO_SNDLOWAT, &oldLow) || !ReadOption(fd, SO_NOSIGPIPE, &oldNoPipe)) break;
        flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) break;
        configured = YES;
        int yes = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes))) break;
        queue = kqueue(); if (queue < 0) break;
        struct kevent change, event;
        struct timespec immediate = {0,0};
        EV_SET(&change, fd, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
        if (kevent(queue, &change, 1, &event, 1, &immediate) != 1 || event.flags & (EV_ERROR | EV_EOF) || event.data <= 0 || event.data > INT_MAX) break;
        int baseline = (int)event.data;
        if (setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &baseline, sizeof(baseline))) break;
        if (!SenderWaitInit(&waiter, queue, fd, STDIN_FILENO, probe.pcmFD, baseline)) break;
        printf("SOCKET fd=%d CID=%04X outgoingMTU=%u type=%d baseline=%d codec=lhdcV5 senderEventWait=1\n", fd, owned.cid, owned.outgoingMTU, socketType, baseline);
        while (!probe.closed && !probe.failed && !probe.inputEnded && !probe.stdinEnded) {
            RunLoopFor(0); // Service queued CoreBluetooth/main-queue callbacks without a fixed sleep.
            PollLiveControls(probe); [probe pollInput];
            if (probe.stopRequested) { success = YES; break; }
            if (probe.failed || probe.closed || probe.inputEnded || probe.stdinEnded) break;
            if (!RecoverLHDCPCM(probe, start, MonotonicTime())) break;
            if (probe.targetGain != codec->targetGain) MacLHDCGain(codec, probe.targetGain);
            if (seconds && codec->consumed >= (uint64_t)seconds * codec->rate) { success = YES; break; }
            double due = LHDCFrameDue(codec, start);
            double readyAt = MonotonicTime();
            ReportLHDCWindow(&statistics, readyAt, 0, NO);
            if (readyAt < due || probe.pcmBytes < codec->block * 8) {
                // Ignore an already-readable PCM pipe while pacing: there is
                // enough buffered audio, and waking on it would busy-spin.
                BOOL starved = readyAt >= due && probe.pcmBytes < codec->block * 8;
                double delay = readyAt < due ? due-readyAt : 0.005;
                if (WaitLHDC(&waiter, &statistics, NO, starved, delay) < 0) { probe.failed=YES; break; }
                continue;
            }
            NSUInteger pcmLength=codec->block*8;
            NSUInteger first=MIN(pcmLength, probe.profile.capacityBytes-probe.pcmHead);
            memcpy(pcm, probe.pcmRing+probe.pcmHead, first);
            memcpy((uint8_t *)pcm+first, probe.pcmRing, pcmLength-first);
            probe.pcmHead = (probe.pcmHead + codec->block * 8) % probe.profile.capacityBytes;
            probe.pcmBytes -= codec->block * 8;
            size_t length = 0; unsigned bitrate = 0;
            double encodeAt=MonotonicTime();
            BOOL encoded=MacLHDCEncode(codec, pcm, packet, sizeof(packet), &length, &bitrate);
            SenderStatisticsEncode(&statistics, MonotonicTime()-encodeAt, fmax(0, readyAt-due));
            if (!encoded) { printf("ENCODER_FAILED codec=lhdcV5 reason=encode-or-MTU\n"); probe.failed = YES; break; }
            if (!length) continue;
            if (length > (size_t)baseline) { probe.failed = YES; break; }
            probe.pcmCanSkip = NO; // The packet's RTP timestamp is already fixed until drain.
            double before = MonotonicTime();
            double drainLimit = probe.profile.catchupLimit + 1.0;
            ssize_t written = send(fd, packet, length, 0);
            // A partial write invalidates the outgoing SDU boundary. Never append a guessed remainder.
            if (written != (ssize_t)length) { printf("ENCODER_FAILED codec=lhdcV5 reason=partial-or-blocked-send wrote=%ld expected=%zu errno=%d\n", written, length, errno); probe.failed = YES; break; }
            pendingSince=before;
            sent++; totalBytes += length;
            BOOL drainedPacket = NO;
            while (!probe.closed && !probe.failed && !probe.stdinEnded && !probe.stopRequested) {
                RunLoopFor(0);
                PollLiveControls(probe); [probe pollInput]; [probe pollPCM];
                drainLimit = fmax(drainLimit, probe.profile.catchupLimit + 1.0);
                if (probe.closed || probe.failed || probe.inputEnded || probe.stdinEnded || probe.stopRequested) break;
                double current=MonotonicTime();
                [probe observeCatchupAt:current due:LHDCFrameDue(codec, start) enabled:YES];
                ReportLHDCWindow(&statistics, current, current-before, NO);
                double remaining=drainLimit-(current-before);
                if (remaining <= 0) break;
                int wake=WaitLHDC(&waiter, &statistics, YES, NO, remaining);
                if (wake < 0) { probe.failed=YES; break; }
                if (wake & SenderWakeDrain) { drainedPacket=YES; break; }
            }
            if (probe.stopRequested) { success = YES; break; }
            if (!drainedPacket) {
                if (!probe.failed && !probe.closed && !probe.inputEnded) printf("DRAIN_LIMIT codec=lhdcV5 packet=%lu\n", sent);
                probe.failed = YES; break;
            }
            drained++;
            SenderStatisticsDrained(&statistics, MonotonicTime()-before, (unsigned)length);
            pendingSince=0;
            if (drained == 1) printf("LIVE_SENT packets=1 rate=%u channels=2 bitrateKbps=%d eqmid=%d\n", codec->rate, probe.profile.bitrateKbps, probe.profile.eqmid);
            if (bitrate != previousBitrate) { printf("LHDC_FORMAT rate=%u channels=2 bitrateKbps=%u bits=%u\n", codec->rate, bitrate, codec->bits); previousBitrate = bitrate; }
            if (!codec->rampRemaining && !probe.gainAckReady) { printf("GAIN_APPLIED gain=%.17g\n", codec->gain); probe.gainAckReady = YES; }
            double now = MonotonicTime(), blocked = now - before, late = fmax(0, now - due);
            if (now >= progress) { printf("LIVE_PROGRESS codec=lhdcV5 sentPackets=%lu drainedPackets=%lu sentBytes=%lu sourceSamples=%llu sentSamples=%llu bufferedFrames=%lu skippedFrames=%llu blocked=%.6f late=%.6f elapsed=%.6f catchupSeconds=%.6f\n", sent, drained, totalBytes, codec->consumed, codec->emitted, probe.pcmBytes / 8, codec->skipped, blocked, late, now - start, probe.catchup.elapsed); progress = now + 1; }
            if (probe.profile.adaptive) {
                int direction = 0;
                if (blocked > 0.008 || late > 0.05) { stableSince = now; if (now - lastAdjustment >= 0.2) direction = -1; }
                else if (now - stableSince >= 10 && now - lastAdjustment >= 10) direction = 1;
                if (direction) { if (!MacLHDCAdjust(codec, direction)) { probe.failed = YES; break; } lastAdjustment = now; printf("ADAPTIVE_TARGET codec=lhdcV5 index=%u direction=%d\n", codec->index, direction); }
            }
        }
    } while (NO);
    double finishedAt=MonotonicTime();
    ReportLHDCWindow(&statistics, finishedAt, pendingSince ? finishedAt-pendingSince : 0, YES);
    probe.pcmComplete = YES;
    if (queue >= 0) close(queue);
    if (configured && !probe.closed && owned.socketFD == fd) {
        if (fcntl(fd, F_SETFL, flags) || setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &oldLow, sizeof(oldLow)) || setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &oldNoPipe, sizeof(oldNoPipe))) success = NO;
    }
    printf("FEED_COMPLETE result=%d codec=lhdcV5 sentPackets=%lu drainedPackets=%lu sentBytes=%lu sourceSamples=%llu sentSamples=%llu elapsed=%.6f closed=%d\n", success && !probe.failed ? 0 : 5, sent, drained, totalBytes, codec->consumed, codec->emitted, MonotonicTime() - start, probe.closed);
    [NSProcessInfo.processInfo endActivity:activity];
    return success && !probe.failed;
}
