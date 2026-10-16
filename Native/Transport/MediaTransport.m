#include "../Codec/LHDCBackend.h"
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#include "ClassicConnection.h"
#include "ParentLifetime.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <limits.h>
#include <math.h>
#include <pthread/qos.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include "ldacBT.h"
#include "ldacBT_ex.h"
#include "AdaptiveLDAC/LDACAdaptivePolicy.h"

#ifndef SONOFERRY_LDAC_PROBE_ONLY
#define SONOFERRY_LDAC_PROBE_ONLY 1
#endif

@interface CBClassicPeer : CBPeer
@property(copy) void (^connectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
@property(copy) void (^disconnectL2CAPCallback)(CBL2CAPChannel *, NSInteger);
- (void)openL2CAPChannel:(UInt16)psm;
- (void)closeL2CAPChannel:(UInt16)psm;
@end

@interface IOBluetoothDevice (ClassicPeerAccess)
@property(readonly) CBClassicPeer *classicPeer;
@end

@interface CBL2CAPChannel (ChannelInspection)
@property(readonly) UInt16 cid;
@property(readonly) UInt16 outgoingMTU;
@property(readonly) int socketFD;
@end

static void RunLoopFor(NSTimeInterval seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static double MonotonicTime(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000000.0;
}

enum { SenderOther, SenderControl, SenderInput, SenderPCM, SenderEncode, SenderPacing, SenderStageCount };

typedef struct {
    int stage;
    double wallAt;
    double cpuAt;
    double wall[SenderStageCount];
    double cpu[SenderStageCount];
    double maximumPacing;
} SenderTiming;

static void RecordSenderStage(SenderTiming *timing, int stage) {
    double wall = MonotonicTime();
    double cpu = (double)clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1000000000.0;
    double duration = wall - timing->wallAt;
    timing->wall[timing->stage] += duration;
    timing->cpu[timing->stage] += cpu - timing->cpuAt;
    if (timing->stage == SenderPacing) timing->maximumPacing = fmax(timing->maximumPacing, duration);
    timing->stage = stage;
    timing->wallAt = wall;
    timing->cpuAt = cpu;
}

static SenderTiming NewSenderTiming(void) {
    return (SenderTiming){.wallAt = MonotonicTime(),
        .cpuAt = (double)clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1000000000.0};
}

static BOOL ReadOption(int fd, int option, int *value) {
    socklen_t length = sizeof(*value);
    return getsockopt(fd, SOL_SOCKET, option, value, &length) == 0;
}

static BOOL ParseUnsigned(NSString *text, uint32_t *value) {
    const char *input = text.UTF8String;
    if (!input || input[0] < '0' || input[0] > '9') return NO;
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(input, &end, 10);
    if (errno || *end || parsed > UINT32_MAX) return NO;
    *value = (uint32_t)parsed;
    return YES;
}

static BOOL ParseDurationSeconds(NSString *text, uint32_t *value) {
#if SONOFERRY_LDAC_PROBE_ONLY
    return ParseUnsigned(text, value) && *value <= 60;
#else
    return ParseUnsigned(text, value) && *value == 0;
#endif
}

static BOOL ParseGain(NSString *text, double *value) {
    const char *input = text.UTF8String;
    if (!input || !*input) return NO;
    errno = 0;
    char *end = NULL;
    double parsed = strtod(input, &end);
    if (errno || end == input || *end || !isfinite(parsed) || parsed < 0 || parsed > 1) return NO;
    *value = parsed;
    return YES;
}

static NSString *NormalizeAddress(const char *value) {
    if (strlen(value) != 17 || (value[2] != ':' && value[2] != '-')) return nil;
    for (NSUInteger index = 0; index < 17; index++) {
        if (index % 3 == 2) {
            if (value[index] != value[2]) return nil;
        } else if (!((value[index] >= '0' && value[index] <= '9') ||
                     (value[index] >= 'a' && value[index] <= 'f') ||
                     (value[index] >= 'A' && value[index] <= 'F'))) return nil;
    }
    return [[[NSString stringWithUTF8String:value] uppercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
}

typedef struct {
    BOOL breached;
    double firstBreach;
    BOOL recovered;
    double recoveryTime;
} RecoveryState;

typedef struct {
    BOOL active;
    double since;
    double elapsed;
} CatchupState;

static void ObserveCatchup(CatchupState *state, double now, double due, BOOL enabled) {
    if (!enabled || now <= due || (state->active && now < state->since)) {
        *state = (CatchupState){0};
    } else {
        if (!state->active) { state->active = YES; state->since = now; }
        state->elapsed = now - state->since;
    }
}

static BOOL RecordBreach(RecoveryState *state, double now) {
    if (state->breached) return NO;
    state->breached = YES;
    state->firstBreach = now;
    return YES;
}

static BOOL RecordRecovery(RecoveryState *state, double now, double lateness) {
    if (!state->breached || state->recovered || lateness >= 0.016 || now - state->firstBreach > 1) return NO;
    state->recovered = YES;
    state->recoveryTime = now;
    return YES;
}

static BOOL RecoveryChecks(void) {
    RecoveryState state = {0};
    BOOL passed = RecordBreach(&state, 10) && !RecordBreach(&state, 10.2) && state.firstBreach == 10;
    passed &= !RecordRecovery(&state, 10.3, 0.016) && RecordRecovery(&state, 11, 0.015);
    passed &= state.breached && state.recovered && state.recoveryTime == 11 && !RecordRecovery(&state, 11.1, 0.001);
    RecoveryState expired = {0};
    passed &= RecordBreach(&expired, 20) && !RecordRecovery(&expired, 21.001, 0.001) && !expired.recovered;
    return passed;
}

enum { PCMBlockBytes = LDACBT_ENC_LSU * 8 };

typedef struct {
    uint32_t sampleRate;
    int eqmid;
    int rateIndex;
    uint32_t frameSamples;
    int frameBytes;
    int bitrateKbps;
    NSUInteger capacityBytes;
    NSUInteger prefillBytes;
    uint32_t gainRampFrames;
    BOOL adaptive;
    double catchupLimit;
} LDACProfile;

typedef struct {
    int frameBytes;
    int bitrateKbps;
} LDACFrameFormat;

static BOOL ConfigureBuffering(LDACProfile *profile, uint32_t limitMs, uint32_t prefillMs) {
    if (limitMs < 100 || limitMs > 15000 || limitMs % 100 || prefillMs < 10 || prefillMs > 1000) return NO;
    profile->catchupLimit = limitMs / 1000.0;
    profile->prefillBytes = (((uint64_t)profile->sampleRate * prefillMs + 999) / 1000) * 8;
    // Reserve all live-adjustable settings up front: no allocation/copy during playback.
    uint64_t frames = (uint64_t)profile->sampleRate * 18;
    profile->capacityBytes = ((frames + 127) / 128) * PCMBlockBytes;
    return YES;
}

static BOOL SelectProfile(uint32_t sampleRate, NSString *quality, LDACProfile *profile) {
    int rateIndex;
    switch (sampleRate) {
        case 44100: rateIndex = 0; break;
        case 48000: rateIndex = 1; break;
        case 88200: rateIndex = 2; break;
        case 96000: rateIndex = 3; break;
        default: return NO;
    }
    int eqmid, multiplier;
    if ([quality isEqualToString:@"low"] || [quality isEqualToString:@"auto"]) { eqmid = LDACBT_EQMID_MQ; multiplier = 1; }
    else if ([quality isEqualToString:@"mid"]) { eqmid = LDACBT_EQMID_SQ; multiplier = 2; }
    else if ([quality isEqualToString:@"high"]) { eqmid = LDACBT_EQMID_HQ; multiplier = 3; }
    else return NO;
    *profile = (LDACProfile){sampleRate, eqmid, rateIndex, sampleRate > 48000 ? 256 : 128,
        multiplier * 110, multiplier * (sampleRate % 44100 == 0 ? 303 : 330),
        ((sampleRate + 127) / 128) * PCMBlockBytes, (sampleRate / 4) * 8, sampleRate / 50,
        [quality isEqualToString:@"auto"]};
    return ConfigureBuffering(profile, 5000, 250);
}

static BOOL AdaptiveQuality(int eqmid) {
    return eqmid == LDACBT_EQMID_MQ || eqmid == LDACBT_EQMID_Q1 || eqmid == LDACBT_EQMID_Q0 ||
        eqmid == LDACBT_EQMID_SQ || eqmid == LDACBT_EQMID_HQ;
}

static BOOL EncoderMatchesProfile(HANDLE_LDAC_BT encoder, LDACProfile profile) {
    return ldacBT_get_sampling_freq(encoder) == profile.sampleRate && (profile.adaptive ?
        AdaptiveQuality(ldacBT_get_eqmid(encoder)) && ldacBT_get_bitrate(encoder) > 0 :
        ldacBT_get_eqmid(encoder) == profile.eqmid && ldacBT_get_bitrate(encoder) == profile.bitrateKbps);
}

static BOOL ResetEncoder(HANDLE_LDAC_BT encoder, int mtu, LDACProfile profile) {
    int eqmid = profile.adaptive ? ldacBT_get_eqmid(encoder) : profile.eqmid;
    if (profile.adaptive && !AdaptiveQuality(eqmid)) return NO;
    int initial = eqmid == LDACBT_EQMID_Q0 || eqmid == LDACBT_EQMID_Q1 ? LDACBT_EQMID_MQ : eqmid;
    ldacBT_close_handle(encoder);
    if (ldacBT_init_handle_encode(encoder, mtu, initial, LDACBT_CHANNEL_MODE_STEREO,
            LDACBT_SMPL_FMT_F32, profile.sampleRate) != 0) return NO;
    while (ldacBT_get_eqmid(encoder) != eqmid) {
        if (ldacBT_alter_eqmid_priority(encoder, LDACBT_EQMID_INC_QUALITY) != 0) return NO;
    }
    return EncoderMatchesProfile(encoder, profile);
}

static int FrameLength(const uint8_t *header, NSUInteger available, LDACProfile profile) {
    if (available < 3 || header[0] != 0xAA || header[1] >> 5 != profile.rateIndex ||
            ((header[1] >> 3) & 3) != LDAC_CCI_STEREO) return 0;
    int payloadBytes = (((header[1] & 7) << 6) | (header[2] >> 2)) + 1;
    if (payloadBytes < 46 || payloadBytes > 327 ||
            (!profile.adaptive && payloadBytes != profile.frameBytes - 3)) return 0;
    return payloadBytes + 3;
}

static BOOL FrameHeadersMatch(const uint8_t *encoded, NSUInteger length, int frames,
                              LDACProfile profile, LDACFrameFormat *latestFrame) {
    if (frames < 0 || frames > 15) return NO;
    NSUInteger offset = 0;
    LDACFrameFormat latest = {profile.frameBytes, profile.bitrateKbps};
    for (int frame = 0; frame < frames; frame++) {
        int bytes = FrameLength(encoded + offset, length - offset, profile);
        if (!bytes || (NSUInteger)bytes > length - offset) return NO;
        latest.frameBytes = bytes;
        latest.bitrateKbps = bytes * profile.sampleRate / profile.frameSamples / 125;
        offset += (NSUInteger)bytes;
    }
    if (offset != length) return NO;
    if (latestFrame && frames) *latestFrame = latest;
    return YES;
}

static BOOL EncodePacket(HANDLE_LDAC_BT encoder, LDACProfile profile, float *pcm,
                         NSUInteger sequence, uint64_t timestamp, NSUInteger mtu, NSUInteger baseline,
                         uint8_t *packet, NSUInteger *packetLength, int *frames, LDACFrameFormat *latestFrame) {
    uint8_t encoded[LDACBT_MAX_NBYTES];
    int used = 0, wrote = 0;
    *frames = 0;
    *packetLength = 0;
    int status = ldacBT_encode(encoder, pcm, &used, encoded, &wrote, frames);
    if (status || used != (pcm ? PCMBlockBytes : 0) || wrote < 0 || wrote > sizeof(encoded) ||
        *frames < 0 || *frames > 15 || (!wrote != !*frames) ||
        (!profile.adaptive && wrote != *frames * profile.frameBytes) ||
        !EncoderMatchesProfile(encoder, profile) ||
        !FrameHeadersMatch(encoded, (NSUInteger)wrote, *frames, profile, latestFrame)) {
        printf("ENCODER_FAILED status=%d code=%d used=%d wrote=%d frames=%d flushing=%d rate=%d eqmid=%d bitrateKbps=%d\n",
               status, ldacBT_get_error_code(encoder), used, wrote, *frames, pcm == NULL,
               ldacBT_get_sampling_freq(encoder), ldacBT_get_eqmid(encoder), ldacBT_get_bitrate(encoder));
        return NO;
    }
    if (!wrote) return YES;
    *packetLength = (NSUInteger)wrote + 13;
    if (*packetLength > mtu || *packetLength > baseline) {
        printf("ENCODER_FAILED reason=packet-boundary bytes=%lu outgoingMTU=%lu baseline=%lu\n",
               *packetLength, mtu, baseline);
        return NO;
    }
    packet[0] = 0x80; packet[1] = 0x60;
    packet[2] = (uint8_t)(sequence >> 8); packet[3] = (uint8_t)sequence;
    packet[4] = (uint8_t)(timestamp >> 24); packet[5] = (uint8_t)(timestamp >> 16);
    packet[6] = (uint8_t)(timestamp >> 8); packet[7] = (uint8_t)timestamp;
    packet[8] = 0x58; packet[9] = 0x4D; packet[10] = 0x35; packet[11] = 0x01;
    packet[12] = (uint8_t)*frames;
    memcpy(packet + 13, encoded, (NSUInteger)wrote);
    return YES;
}

static uint64_t EncodedSampleLimit(uint64_t sourceSamples, LDACProfile profile) {
    uint64_t inputSamples = ((sourceSamples + 127) / 128) * 128;
    return ((inputSamples + profile.frameSamples - 1) / profile.frameSamples + 1) * profile.frameSamples;
}

static double PacketDue(double started, uint64_t timestamp, LDACProfile profile) {
    return started + (double)timestamp / profile.sampleRate;
}

static NSUInteger PCMSkipAlignedBytes(NSUInteger buffered, NSUInteger reserve, uint64_t maximumFrames, NSUInteger blockFrames) {
    if (buffered <= reserve || !blockFrames) return 0;
    NSUInteger blockBytes = blockFrames * 8;
    uint64_t blocks = MIN((uint64_t)((buffered - reserve) / blockBytes), maximumFrames / blockFrames);
    return (NSUInteger)blocks * blockBytes;
}

static NSUInteger PCMSkipBytes(NSUInteger buffered, NSUInteger reserve, uint64_t maximumFrames) {
    return PCMSkipAlignedBytes(buffered, reserve, maximumFrames, 128);
}

static BOOL ContinuousPCMChecks(void);
static BOOL PreparedPCMChecks(void);
static BOOL PreparedPCMStopChecks(void);

static BOOL ConvertRampedPCM(const uint8_t *bytes, NSUInteger frames, double *gain, double target, uint32_t *remaining, float *output) {
    for (NSUInteger frame = 0; frame < frames; frame++) {
        if (*remaining) {
            *gain += (target - *gain) / *remaining;
            if (!--*remaining) *gain = target;
        }
        for (NSUInteger channel = 0; channel < 2; channel++) {
            NSUInteger sample = frame * 2 + channel;
            float input;
            memcpy(&input, bytes + sample * sizeof(input), sizeof(input));
            double value = (double)input * *gain;
            if (!isfinite(input) || !isfinite(value)) return NO;
            output[sample] = (float)fmax(-1, fmin(1, value));
        }
    }
    memset(output + frames * 2, 0, (128 - frames) * 2 * sizeof(*output));
    return YES;
}

static BOOL ConvertPCM(const uint8_t *bytes, double gain, float *output) {
    uint32_t remaining = 0;
    return ConvertRampedPCM(bytes, 128, &gain, gain, &remaining, output);
}

static BOOL MatrixChecks(void) {
    const uint32_t rates[] = {44100, 48000, 88200, 96000};
    const uint64_t sourceLengths[] = {24 * 128, 25 * 128, 25 * 128 - 13, 25 * 128};
    NSArray<NSString *> *qualities = @[@"low", @"mid", @"high"];
    BOOL passed = YES;
    for (NSUInteger rate = 0; rate < 4; rate++) {
        for (NSUInteger quality = 0; quality < qualities.count; quality++) {
            LDACProfile profile;
            if (!SelectProfile(rates[rate], qualities[quality], &profile)) return NO;
            passed &= profile.capacityBytes % PCMBlockBytes == 0 && profile.capacityBytes / 8 >= (uint64_t)rates[rate] * 18 &&
                profile.capacityBytes / 8 < (uint64_t)rates[rate] * 18 + 128 && profile.prefillBytes / 8 == rates[rate] / 4;
            float rampInput[256], rampOutput[256];
            for (NSUInteger sample = 0; sample < 256; sample++) rampInput[sample] = 1;
            double rampGain = 0;
            uint32_t rampRemaining = profile.gainRampFrames;
            passed &= fabs((double)rampRemaining / profile.sampleRate - 0.02) < 1e-12;
            while (rampRemaining) {
                if (!ConvertRampedPCM((const uint8_t *)rampInput, 128, &rampGain, 0.025, &rampRemaining, rampOutput)) return NO;
                passed &= rampGain > 0 && rampGain <= 0.025;
            }
            passed &= rampGain == 0.025 && rampOutput[255] == (float)0.025;
            for (NSUInteger fixture = 0; fixture < 4; fixture++) {
                HANDLE_LDAC_BT encoder = ldacBT_get_handle();
                if (!encoder || ldacBT_init_handle_encode(encoder, 679, profile.eqmid,
                        LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, profile.sampleRate) != 0) {
                    if (encoder) ldacBT_free_handle(encoder);
                    return NO;
                }
                passed &= EncoderMatchesProfile(encoder, profile);
                uint64_t sourceSamples = 0, generatedSamples = 0;
                NSUInteger packets = 0;
                unsigned int flushCalls = 0;
                while (YES) {
                    BOOL flushing = sourceSamples == sourceLengths[fixture];
                    float input[256] = {0}, pcm[256];
                    if (flushing) {
                        if (++flushCalls > 16) { passed = NO; break; }
                    } else {
                        NSUInteger frames = MIN((uint64_t)128, sourceLengths[fixture] - sourceSamples);
                        for (NSUInteger frame = 0; fixture && frame < frames; frame++) {
                            double time = (double)(sourceSamples + frame) / profile.sampleRate;
                            input[frame * 2] = (float)(0.2 * sin(2 * M_PI * 431 * time) + 0x1p-20);
                            input[frame * 2 + 1] = (float)(0.15 * sin(2 * M_PI * 713 * time) +
                                (profile.sampleRate > 48000 ? 0.05 * sin(2 * M_PI * 32000 * time) : 0));
                        }
                        BOOL overrange = fixture == 3 && !sourceSamples;
                        if (overrange) { input[0] = 1.25; input[1] = -1.25; }
                        double gain = 1;
                        uint32_t remaining = 0;
                        if (!ConvertRampedPCM((const uint8_t *)input, frames, &gain, 1, &remaining, pcm)) { passed = NO; break; }
                        if (overrange) passed &= pcm[0] == 1 && pcm[1] == -1;
                        else passed &= !memcmp(input, pcm, sizeof(input));
                        sourceSamples += frames;
                    }
                    uint8_t packet[LDACBT_MAX_NBYTES + 13];
                    NSUInteger length = 0;
                    int frames = 0;
                    if (!EncodePacket(encoder, profile, flushing ? NULL : pcm, packets, generatedSamples,
                            679, 679, packet, &length, &frames, NULL)) { passed = NO; break; }
                    if (!length) { if (flushing) break; continue; }
                    uint16_t sequence = (uint16_t)packet[2] << 8 | packet[3];
                    uint32_t timestamp = (uint32_t)packet[4] << 24 | (uint32_t)packet[5] << 16 |
                        (uint32_t)packet[6] << 8 | packet[7];
                    passed &= packet[0] == 0x80 && packet[1] == 0x60 && sequence == packets &&
                        timestamp == generatedSamples && !memcmp(packet + 8, "XM5\x01", 4) && packet[12] == frames &&
                        length == 13 + frames * profile.frameBytes && length <= 673 &&
                        FrameHeadersMatch(packet + 13, length - 13, frames, profile, NULL);
                    packet[13] ^= 1;
                    passed &= !FrameHeadersMatch(packet + 13, length - 13, frames, profile, NULL);
                    generatedSamples += (uint64_t)frames * profile.frameSamples;
                    passed &= fabs(PacketDue(10, generatedSamples, profile) - 10 -
                        (double)generatedSamples / profile.sampleRate) < 1e-12;
                    packets++;
                }
                passed &= packets > 0 && sourceSamples == sourceLengths[fixture] &&
                    generatedSamples == EncodedSampleLimit(sourceSamples, profile);
                printf("MATRIX_CHECK rate=%u quality=%s bitrateKbps=%d fixture=%lu sourceSamples=%llu generatedSamples=%llu paddingSamples=%llu packets=%lu\n",
                       profile.sampleRate, qualities[quality].UTF8String, ldacBT_get_bitrate(encoder), fixture,
                       sourceSamples, generatedSamples, generatedSamples - sourceSamples, packets);
                ldacBT_free_handle(encoder);
            }
        }
    }
    LDACProfile invalid;
    passed &= !SelectProfile(32000, @"low", &invalid) && !SelectProfile(48000, @"adaptive", &invalid);
    passed &= SelectProfile(48000, @"auto", &invalid) && invalid.adaptive &&
        invalid.eqmid == LDACBT_EQMID_MQ && invalid.frameBytes == 110 && invalid.bitrateKbps == 330;
    return passed;
}

static BOOL SelfTest(void) {
    float input[256] = {0};
    float output[256] = {0};
    input[0] = 1; input[1] = -1;
    BOOL passed = RecoveryChecks() && ContinuousPCMChecks() && PreparedPCMChecks() && PreparedPCMStopChecks() && ConvertPCM((const uint8_t *)input, 0.5, output);
    passed &= output[0] == 0.5 && output[1] == -0.5 && output[255] == 0;
    const float invalid[] = {NAN, INFINITY, -INFINITY};
    for (NSUInteger sample = 0; sample < 3; sample++) {
        for (NSUInteger position = 0; position < 256; position += 255) {
            input[position] = invalid[sample];
            passed &= !ConvertPCM((const uint8_t *)input, 0, output) &&
                !ConvertPCM((const uint8_t *)input, 0.025, output) && !ConvertPCM((const uint8_t *)input, 1, output);
            input[position] = 0;
        }
    }
    input[0] = 1.25; input[1] = -1.25;
    input[2] = nextafterf(1, 2); input[3] = nextafterf(-1, -2);
    input[4] = 0x1.fffffep127f; input[5] = -0x1.fffffep127f;
    passed &= ConvertPCM((const uint8_t *)input, 1, output);
    for (NSUInteger sample = 0; sample < 6; sample++) passed &= output[sample] == (sample % 2 ? -1 : 1);
    passed &= ConvertPCM((const uint8_t *)input, 0.5, output) && output[0] == 0.625 && output[1] == -0.625;
    passed &= ConvertPCM((const uint8_t *)input, 0, output);
    for (NSUInteger sample = 0; sample < 256; sample++) passed &= output[sample] == 0;
    const float unity[] = {-1, -0.75, -0.0f, 0, 0x1p-20f, 0.25, 0x1.fffffep-1f, 1};
    for (NSUInteger sample = 0; sample < 256; sample++) input[sample] = unity[sample % 8];
    passed &= ConvertPCM((const uint8_t *)input, 1, output) && !memcmp(input, output, sizeof(input));
    for (NSUInteger sample = 0; sample < 256; sample++) input[sample] = 1;
    double gain = 0;
    uint32_t remaining = 960;
    for (NSUInteger block = 0; block < 7; block++) passed &= ConvertRampedPCM((const uint8_t *)input, 128, &gain, 0.025, &remaining, output);
    passed &= remaining == 64 && gain > 0 && gain < 0.025;
    passed &= ConvertRampedPCM((const uint8_t *)input, 128, &gain, 0.025, &remaining, output);
    passed &= remaining == 0 && gain == 0.025 && output[255] == (float)0.025;
    for (NSUInteger sample = 0; sample < 256; sample++) input[sample] = sample % 2 ? -1.25 : 1.25;
    gain = 0.5; remaining = 960;
    passed &= ConvertRampedPCM((const uint8_t *)input, 128, &gain, 1, &remaining, output) &&
        output[0] > 0.625 && output[0] < 1 && output[1] == -output[0];
    for (NSUInteger block = 1; block < 8; block++) passed &= ConvertRampedPCM((const uint8_t *)input, 128, &gain, 1, &remaining, output);
    passed &= remaining == 0 && gain == 1 && output[0] == 1 && output[255] == -1;
    remaining = 960;
    passed &= ConvertRampedPCM((const uint8_t *)input, 128, &gain, 0.5, &remaining, output) && output[0] == 1 && output[1] == -1;
    for (NSUInteger block = 1; block < 8; block++) passed &= ConvertRampedPCM((const uint8_t *)input, 128, &gain, 0.5, &remaining, output);
    passed &= remaining == 0 && gain == 0.5 && output[0] > 0.625 && output[0] < 1 && output[255] == -0.625;
    passed &= ConvertRampedPCM((const uint8_t *)input, 128, &gain, 0.5, &remaining, output) && output[0] == 0.625 && output[255] == -0.625;
    uint32_t seconds = 0;
    passed &= ParseDurationSeconds(@"0", &seconds) && seconds == 0 &&
        !ParseDurationSeconds(@"61", &seconds) && !ParseDurationSeconds(@"0x", &seconds) &&
        !ParseDurationSeconds(@"4294967296", &seconds);
    passed &= ParseDurationSeconds(@"1", &seconds) == SONOFERRY_LDAC_PROBE_ONLY &&
        ParseDurationSeconds(@"60", &seconds) == SONOFERRY_LDAC_PROBE_ONLY;
    passed &= ParseGain(@"0", &gain) && gain == 0 && !ParseGain(@"nan", &gain) && !ParseGain(@"1.01", &gain);
    passed &= [NormalizeAddress("02:00:00:00:00:ab") isEqualToString:@"02-00-00-00-00-AB"] && !NormalizeAddress("02-00-00-00-00-G6");
    return MatrixChecks() && passed;
}

@interface DirectMediaProbe : NSObject
@property BOOL closed;
@property BOOL failed;
@property BOOL openFailed;
@property BOOL inputEnded;
@property NSUInteger received;
@property UInt16 realCID;
@property LDACProfile profile;
@property int pcmFD;
@property uint8_t *pcmRing;
@property NSUInteger pcmHead;
@property NSUInteger pcmBytes;
@property uint64_t pcmReadBytes;
@property uint64_t pcmDiscardedBytes;
@property uint64_t pcmSkippedBytes;
@property BOOL pcmActive;
@property BOOL pcmStarted;
@property BOOL pcmContinuous;
@property BOOL pcmCanSkip;
@property NSUInteger pcmReserveBytes;
@property BOOL pcmReady;
@property BOOL pcmComplete;
@property BOOL pcmEnded;
@property HANDLE_LDAC_BT encoder;
@property MacLHDC *lhdcEncoder;
@property int encoderMTU;
@property CatchupState catchup;
@property BOOL stdinEnded;
@property BOOL stopRequested;
@property BOOL closeRequested;
@property double gain;
@property double targetGain;
@property uint32_t gainRampRemaining;
@property BOOL gainAckReady;
@property(strong) NSMutableData *controlPending;
@property(strong) CBL2CAPChannel *channel;
@property(strong) NSInputStream *input;
@property(strong) NSOutputStream *output;
- (void)pollInput;
- (void)pollPCM;
- (NSUInteger)discardPCMFrames:(uint64_t)maximumFrames;
- (void)observeCatchupAt:(double)now due:(double)due enabled:(BOOL)enabled;
- (NSUInteger)recoverCatchupAt:(double)now due:(double)due;
@end

@implementation DirectMediaProbe
- (void)dealloc {
    if (_encoder) ldacBT_free_handle(_encoder);
    if (_lhdcEncoder) { MacLHDCClose(_lhdcEncoder); free(_lhdcEncoder); }
    free(_pcmRing);
    if (_pcmFD >= 0) close(_pcmFD);
}
- (NSUInteger)discardPCMFrames:(uint64_t)maximumFrames {
    if (!self.pcmContinuous || !self.pcmCanSkip || self.pcmComplete) return 0;
    NSUInteger bytes = PCMSkipAlignedBytes(self.pcmBytes, self.pcmReserveBytes, maximumFrames,
                                           self.lhdcEncoder ? self.lhdcEncoder->block : 128);
    if (!bytes) return 0;
    if (self.pcmSkippedBytes > UINT64_MAX - bytes || self.pcmDiscardedBytes > UINT64_MAX - bytes) {
        printf("PCM_FAILED reason=discard-counter-overflow\n");
        self.failed = YES;
        return 0;
    }
    if (self.lhdcEncoder && !MacLHDCDiscontinuity(self.lhdcEncoder, bytes / 8)) {
        printf("PCM_FAILED reason=lhdc-recovery-reset\n"); self.failed = YES; return 0;
    }
    self.pcmHead = (self.pcmHead + bytes) % self.profile.capacityBytes;
    self.pcmBytes -= bytes;
    self.pcmSkippedBytes += bytes;
    self.pcmDiscardedBytes += bytes;
    printf("PCM_SKIP frames=%lu totalSkippedFrames=%llu bufferedFrames=%lu\n",
           bytes / 8, self.pcmSkippedBytes / 8, self.pcmBytes / 8);
    if (self.lhdcEncoder) {
        printf("PCM_ENCODER_RESET codec=lhdcV5 skippedFrames=%lu totalSkippedFrames=%llu rate=%u index=%u\n",
               bytes / 8, self.pcmSkippedBytes / 8, self.lhdcEncoder->rate, self.lhdcEncoder->index);
    } else if (!ResetEncoder(self.encoder, self.encoderMTU, self.profile)) {
        printf("PCM_FAILED reason=encoder-reset code=%d\n", ldacBT_get_error_code(self.encoder));
        self.failed = YES;
    } else {
        printf("PCM_ENCODER_RESET skippedFrames=%lu totalSkippedFrames=%llu rate=%d bitrateKbps=%d eqmid=%d\n",
               bytes / 8, self.pcmSkippedBytes / 8, ldacBT_get_sampling_freq(self.encoder),
               ldacBT_get_bitrate(self.encoder), ldacBT_get_eqmid(self.encoder));
    }
    return bytes / 8;
}
- (void)observeCatchupAt:(double)now due:(double)due enabled:(BOOL)enabled {
    CatchupState state = self.catchup;
    ObserveCatchup(&state, now, due, enabled && self.pcmContinuous && !self.stopRequested && !self.pcmComplete);
    self.catchup = state;
}
- (NSUInteger)recoverCatchupAt:(double)now due:(double)due {
    [self observeCatchupAt:now due:due enabled:YES];
    if (!self.catchup.active || self.catchup.elapsed + 1e-9 < self.profile.catchupLimit || !self.pcmCanSkip) return 0;
    double elapsed = self.catchup.elapsed;
    NSUInteger frames = [self discardPCMFrames:UINT64_MAX];
    if (frames) {
        self.catchup = (CatchupState){0};
        printf("PCM_RECOVERY codec=%s reason=catchup-timeout catchupSeconds=%.6f limitSeconds=%.1f skippedFrames=%lu bufferedFrames=%lu\n",
               self.lhdcEncoder ? "lhdcV5" : "ldac", elapsed, self.profile.catchupLimit, frames, self.pcmBytes / 8);
    }
    return frames;
}
- (void)pollPCM {
    if (!self.pcmActive || self.pcmEnded || (self.failed && !self.pcmComplete)) return;
    // Limit pipe work per turn so a continuous producer cannot starve sending.
    NSUInteger budget = 65536;
    while (budget) {
        uint8_t discarded[4096];
        if (!self.pcmStarted && !self.pcmComplete) {
            NSUInteger bytes = PCMSkipBytes(self.pcmBytes, self.profile.prefillBytes, UINT64_MAX);
            self.pcmHead = (self.pcmHead + bytes) % self.profile.capacityBytes;
            self.pcmBytes -= bytes;
            self.pcmDiscardedBytes += bytes;
        }
        NSUInteger available = self.profile.capacityBytes - self.pcmBytes;
        // Storage never triggers a skip. Pause reads until the sender reaches
        // a safe boundary; only its continuous catch-up timer may discard PCM.
        if (!available && !self.pcmComplete && self.pcmContinuous) return;
        NSUInteger tail = (self.pcmHead + self.pcmBytes) % self.profile.capacityBytes;
        NSUInteger maximum = MIN(available, self.profile.capacityBytes - tail);
        uint8_t *destination = self.pcmRing + tail;
        if (self.pcmComplete || !available) { destination = discarded; maximum = self.pcmComplete ? sizeof(discarded) : 1; }
        maximum = MIN(maximum, budget);
        ssize_t count = read(self.pcmFD, destination, maximum);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (count <= 0) {
            self.pcmEnded = YES;
            if (self.pcmComplete && !count) {
                printf("PCM_END completed=1 readBytes=%llu discardedBytes=%llu\n", self.pcmReadBytes, self.pcmDiscardedBytes);
                return;
            }
            printf("PCM_FAILED reason=%s errno=%d bufferedBytes=%lu partialFrameBytes=%lu\n",
                   count < 0 ? "read" : "early-eof", count < 0 ? errno : 0, self.pcmBytes, self.pcmBytes % 8);
            self.failed = YES;
            return;
        }
        self.pcmReadBytes += (uint64_t)count;
        budget -= (NSUInteger)count;
        if (self.pcmComplete) { self.pcmDiscardedBytes += (uint64_t)count; continue; }
        if (!available) {
            printf("PCM_FAILED reason=ring-overflow capacityFrames=%lu readBytes=%llu\n", self.profile.capacityBytes / 8, self.pcmReadBytes);
            self.failed = YES;
            return;
        }
        self.pcmBytes += (NSUInteger)count;
        if (!self.pcmReady && self.pcmBytes >= self.profile.prefillBytes) {
            self.pcmReady = YES;
            printf("PCM_READY frames=%lu rate=%u channels=2 format=F32 bufferedFrames=%lu\n",
                   self.profile.prefillBytes / 8, self.profile.sampleRate, self.pcmBytes / 8);
        }
    }
}
- (void)pollInput {
    if (self.closed || self.failed || self.inputEnded || !self.input) return;
    while (self.input.hasBytesAvailable) {
        uint8_t bytes[4096];
        NSInteger length = [self.input read:bytes maxLength:sizeof(bytes)];
        printf("MEDIA_RX time=%.6f channel=%p length=%ld\n", NSDate.date.timeIntervalSince1970,
               (__bridge void *)self.channel, length);
        if (length < 0) { self.failed = YES; return; }
        if (!length) { self.inputEnded = YES; return; }
        self.received += (NSUInteger)length;
    }
    if (self.input.streamStatus == NSStreamStatusError || self.input.streamStatus == NSStreamStatusAtEnd) {
        printf("MEDIA_INPUT_TERMINAL time=%.6f status=%lu error=%s\n", NSDate.date.timeIntervalSince1970,
               self.input.streamStatus, self.input.streamError.description.UTF8String);
        self.inputEnded = self.input.streamStatus == NSStreamStatusAtEnd;
        self.failed = self.input.streamStatus == NSStreamStatusError;
    }
}
@end

static BOOL ContinuousPCMChecks(void) {
    LDACProfile profile;
    if (!SelectProfile(48000, @"low", &profile)) return NO;
    BOOL passed = PCMSkipBytes(profile.prefillBytes, profile.prefillBytes, UINT64_MAX) == 0;
    passed &= PCMSkipBytes(profile.prefillBytes + PCMBlockBytes - 1, profile.prefillBytes, UINT64_MAX) == 0;
    passed &= PCMSkipBytes(profile.prefillBytes + PCMBlockBytes * 3 + 7, profile.prefillBytes, 255) == PCMBlockBytes;
    DirectMediaProbe *probe = [DirectMediaProbe new];
    probe.pcmFD = -1;
    probe.profile = profile;
    probe.encoderMTU = 679;
    probe.encoder = ldacBT_get_handle();
    if (!probe.encoder || ldacBT_init_handle_encode(probe.encoder, probe.encoderMTU, profile.eqmid,
            LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, profile.sampleRate) != 0) return NO;
    probe.pcmReserveBytes = profile.prefillBytes;
    probe.pcmHead = profile.capacityBytes - PCMBlockBytes;
    probe.pcmBytes = profile.prefillBytes + PCMBlockBytes * 3 + 7;
    probe.pcmContinuous = YES;
    passed &= [probe discardPCMFrames:384] == 0 && probe.pcmSkippedBytes == 0;
    probe.pcmCanSkip = YES;
    passed &= [probe discardPCMFrames:384] == 384;
    passed &= probe.pcmHead == PCMBlockBytes * 2 && probe.pcmBytes == profile.prefillBytes + 7;
    passed &= probe.pcmSkippedBytes == PCMBlockBytes * 3 && probe.pcmDiscardedBytes == probe.pcmSkippedBytes;
    uint64_t encodedSamples = 768;
    uint64_t timestamp = encodedSamples + probe.pcmSkippedBytes / 8;
    passed &= timestamp == 1152 && timestamp > encodedSamples;
    probe.pcmBytes = profile.capacityBytes;
    passed &= [probe discardPCMFrames:UINT64_MAX] > 0 && probe.pcmBytes >= profile.prefillBytes && probe.pcmBytes < profile.prefillBytes + PCMBlockBytes;
    uint64_t skipped = probe.pcmSkippedBytes;
    probe.pcmBytes += PCMBlockBytes;
    probe.pcmComplete = YES;
    passed &= [probe discardPCMFrames:UINT64_MAX] == 0 && probe.pcmSkippedBytes == skipped;
    probe.pcmComplete = NO;
    probe.pcmContinuous = NO;
    passed &= [probe discardPCMFrames:UINT64_MAX] == 0 && probe.pcmSkippedBytes == skipped;
    RecoveryState state = {0};
    passed &= RecordBreach(&state, 10) && RecordRecovery(&state, 10.1, 0.001) && state.breached;
    int descriptors[2];
    if (pipe(descriptors) != 0) return NO;
    probe.pcmFD = descriptors[0];
    probe.pcmRing = calloc(1, profile.capacityBytes);
    if (!probe.pcmRing || fcntl(probe.pcmFD, F_SETFL, O_NONBLOCK) != 0) {
        close(descriptors[1]);
        return NO;
    }
    probe.pcmHead = 0;
    probe.pcmBytes = profile.capacityBytes;
    probe.pcmSkippedBytes = 0;
    probe.pcmDiscardedBytes = 0;
    probe.pcmContinuous = YES;
    probe.pcmActive = YES;
    probe.pcmStarted = YES;
    uint8_t input[PCMBlockBytes + 7] = {0};
    passed &= write(descriptors[1], input, sizeof(input)) == sizeof(input);
    [probe pollPCM];
    passed &= !probe.failed && probe.pcmReadBytes == 0 && probe.pcmSkippedBytes == 0;
    [probe recoverCatchupAt:10 due:9];
    passed &= [probe recoverCatchupAt:15 due:14] > 0;
    [probe pollPCM];
    passed &= !probe.failed && probe.pcmReadBytes == sizeof(input) && probe.pcmBytes < profile.capacityBytes;
    passed &= probe.pcmHead % PCMBlockBytes == 0 && probe.pcmBytes % PCMBlockBytes == 7;
    passed &= probe.pcmBytes + probe.pcmSkippedBytes == profile.capacityBytes + sizeof(input);
    probe.pcmComplete = YES;
    close(descriptors[1]);
    [probe pollPCM];
    passed &= probe.pcmEnded && !probe.failed;
    return passed;
}

static BOOL PreparedPCMChecks(void) {
    BOOL passed = YES;
    const uint32_t rates[] = {44100, 48000, 88200, 96000};
    for (NSUInteger index = 0; index < sizeof(rates) / sizeof(rates[0]); index++) {
        LDACProfile profile;
        if (!SelectProfile(rates[index], @"high", &profile)) return NO;
        int descriptors[2];
        if (pipe(descriptors) != 0) return NO;
        DirectMediaProbe *probe = [DirectMediaProbe new];
        probe.pcmFD = descriptors[0];
        probe.profile = profile;
        probe.pcmRing = calloc(1, profile.capacityBytes);
        if (!probe.pcmRing || fcntl(probe.pcmFD, F_SETFL, O_NONBLOCK) != 0) {
            close(descriptors[1]);
            return NO;
        }
        probe.pcmActive = YES;
        NSUInteger produced = 0;
        uint8_t input[PCMBlockBytes + 7];
        while (produced < profile.capacityBytes * 3 && !probe.failed) {
            for (NSUInteger byte = 0; byte < sizeof(input); byte++) input[byte] = (uint8_t)((produced + byte) % 251);
            if (write(descriptors[1], input, sizeof(input)) != sizeof(input)) { passed = NO; break; }
            produced += sizeof(input);
            [probe pollPCM];
        }
        passed &= !probe.failed && probe.pcmReady && probe.pcmReadBytes == produced && probe.pcmSkippedBytes == 0;
        passed &= probe.pcmBytes >= profile.prefillBytes && probe.pcmBytes < profile.prefillBytes + PCMBlockBytes;
        passed &= probe.pcmBytes + probe.pcmDiscardedBytes == produced && probe.pcmHead % PCMBlockBytes == 0;
        for (NSUInteger byte = 0; byte < probe.pcmBytes; byte++) {
            passed &= probe.pcmRing[(probe.pcmHead + byte) % profile.capacityBytes] == (uint8_t)((produced - probe.pcmBytes + byte) % 251);
        }
        NSUInteger retained = probe.pcmBytes;
        uint64_t discarded = probe.pcmDiscardedBytes;
        probe.pcmStarted = YES;
        passed &= write(descriptors[1], input, sizeof(input)) == sizeof(input);
        [probe pollPCM];
        passed &= !probe.failed && probe.pcmBytes == retained + sizeof(input) && probe.pcmDiscardedBytes == discarded;
        probe.pcmComplete = YES;
        close(descriptors[1]);
        [probe pollPCM];
        passed &= probe.pcmEnded && !probe.failed;
    }
    return passed;
}

static NSString *AvailableCommand(DirectMediaProbe *probe) {
    while (!probe.stdinEnded) {
        struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
        int status = poll(&descriptor, 1, 0);
        if (status < 0) {
            if (errno == EINTR) continue;
            printf("STDIN_ERROR errno=%d\n", errno);
            probe.failed = YES;
            probe.stdinEnded = YES;
            probe.stopRequested = YES;
            return nil;
        }
        if (!(descriptor.revents & (POLLIN | POLLHUP | POLLERR))) return nil;
        char value;
        ssize_t count = read(STDIN_FILENO, &value, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count != 1) {
            printf("STDIN_END count=%zd errno=%d partialBytes=%lu\n", count, count < 0 ? errno : 0, probe.controlPending.length);
            if (count < 0 || probe.controlPending.length) probe.failed = YES;
            probe.stdinEnded = YES;
            probe.stopRequested = YES;
            return nil;
        }
        if (value == '\n') {
            NSString *line = [[NSString alloc] initWithData:probe.controlPending encoding:NSUTF8StringEncoding];
            [probe.controlPending setLength:0];
            if (!line) { printf("STDIN_INVALID encoding\n"); probe.failed = YES; probe.stopRequested = YES; }
            return line;
        }
        if (probe.controlPending.length >= 4096) {
            printf("STDIN_INVALID command too long\n");
            probe.failed = YES;
            probe.stdinEnded = YES;
            probe.stopRequested = YES;
            return nil;
        }
        [probe.controlPending appendBytes:&value length:1];
    }
    return nil;
}

static NSString *ReadCommand(DirectMediaProbe *probe) {
    while (YES) {
        NSString *command = AvailableCommand(probe);
        if ([command isEqualToString:@"stop"] && !probe.pcmStarted) {
            probe.stopRequested = YES;
            probe.pcmComplete = YES;
            printf("PCM_STOP_READY started=0\n");
        }
        if (command || probe.stdinEnded) return command;
        [probe pollInput];
        [probe pollPCM];
        RunLoopFor(0.001);
    }
}

static BOOL PreparedPCMStopChecks(void) {
    LDACProfile profile;
    if (!SelectProfile(96000, @"high", &profile)) return NO;
    BOOL passed = YES;
    for (NSUInteger stopped = 0; stopped < 2; stopped++) {
        int pcm[2], control[2];
        if (pipe(pcm) != 0) return NO;
        if (pipe(control) != 0) { close(pcm[0]); close(pcm[1]); return NO; }
        DirectMediaProbe *probe = [DirectMediaProbe new];
        probe.pcmFD = pcm[0];
        probe.profile = profile;
        probe.pcmRing = calloc(1, profile.capacityBytes);
        probe.controlPending = [NSMutableData data];
        int savedInput = dup(STDIN_FILENO);
        if (!probe.pcmRing || savedInput < 0 || fcntl(probe.pcmFD, F_SETFL, O_NONBLOCK) != 0 || dup2(control[0], STDIN_FILENO) < 0) {
            if (savedInput >= 0) close(savedInput);
            close(pcm[1]); close(control[0]); close(control[1]);
            return NO;
        }
        probe.pcmActive = YES;
        uint8_t input[PCMBlockBytes + 7] = {0};
        passed &= write(pcm[1], input, sizeof(input)) == sizeof(input);
        [probe pollPCM];
        if (stopped) {
            passed &= write(control[1], "stop\n", 5) == 5;
            passed &= [ReadCommand(probe) isEqualToString:@"stop"];
            passed &= probe.stopRequested && probe.pcmComplete && !probe.pcmStarted;
        }
        close(pcm[1]);
        [probe pollPCM];
        passed &= probe.pcmEnded && probe.failed == !stopped;
        passed &= dup2(savedInput, STDIN_FILENO) >= 0;
        close(savedInput); close(control[0]); close(control[1]);
    }
    return passed;
}

static BOOL ApplyLiveBuffering(DirectMediaProbe *probe, NSString *command) {
    NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
    uint32_t limit = 0, prefill = 0;
    if (parts.count != 4 || ![[NSUUID alloc] initWithUUIDString:parts[1]] ||
        !ParseUnsigned(parts[2], &limit) || !ParseUnsigned(parts[3], &prefill)) return NO;
    LDACProfile updated = probe.profile;
    if (!ConfigureBuffering(&updated, limit, prefill) || updated.capacityBytes != probe.profile.capacityBytes) return NO;
    if (probe.stopRequested || probe.pcmComplete) return YES; // Stop always wins.
    if (!probe.pcmStarted || !probe.pcmContinuous) return NO;
    probe.profile = updated;
    probe.pcmReserveBytes = updated.prefillBytes;
    probe.catchup = (CatchupState){0};
    printf("BUFFERING_APPLIED request=%s catchupLimitMs=%u prefillMs=%u\n", parts[1].UTF8String, limit, prefill);
    return YES;
}

static void PollLiveControls(DirectMediaProbe *probe) {
    NSString *command;
    unsigned commands = 0;
    while (commands++ < 16 && (command = AvailableCommand(probe))) {
        if ([command isEqualToString:@"stop"] || [command isEqualToString:@"close"]) {
            probe.stopRequested = YES;
            probe.closeRequested |= [command isEqualToString:@"close"];
            printf("STOP_REQUESTED source=stdin close=%d\n", probe.closeRequested);
        } else if ([command hasPrefix:@"buffering "]) {
            if (!ApplyLiveBuffering(probe, command)) {
                printf("COMMAND_REJECTED reason=invalid-buffering\n"); probe.failed = YES;
            }
        } else if ([command hasPrefix:@"gain "]) {
            double gain = 0;
            if (ParseGain([command substringFromIndex:5], &gain)) {
                if (gain == probe.targetGain) continue;
                probe.targetGain = gain;
                probe.gainRampRemaining = probe.profile.gainRampFrames;
                probe.gainAckReady = NO;
                printf("GAIN_REQUESTED gain=%.17g rampFrames=%u\n", gain, probe.profile.gainRampFrames);
            } else {
                printf("COMMAND_REJECTED reason=invalid-gain\n");
                probe.failed = YES;
            }
        } else {
            printf("COMMAND_REJECTED reason=unexpected-live-control command=%s\n", command.UTF8String);
            probe.failed = YES;
        }
    }
    if (probe.stopRequested) probe.pcmComplete = YES;
}

static BOOL FeedLive(DirectMediaProbe *probe, CBL2CAPChannel *owned, double gain, uint32_t seconds) {
    probe.pcmStarted = YES;
    id activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"LDAC streaming"];
    int qos = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    printf("STREAM_ACTIVITY qosStatus=%d\n", qos);
    LDACProfile profile = probe.profile;
    LDACFrameFormat transmittedFormat = {profile.frameBytes, profile.bitrateKbps};
    LDACAdaptivePolicy adaptivePolicy = LDACAdaptivePolicyInit();
    BOOL adaptiveSourceReady = YES;
    uint64_t adaptiveSkippedBytes = probe.pcmSkippedBytes;
    int result = 5;
    int fd = owned.socketFD;
    NSData *native = [probe.output propertyForKey:(__bridge NSString *)kCFStreamPropertySocketNativeHandle];
    int outputFD = -1;
    if ([native isKindOfClass:NSData.class] && native.length == sizeof(outputFD)) [native getBytes:&outputFD length:sizeof(outputFD)];
    printf("STREAM_NATIVE_FD stored=%d output=%d\n", fd, outputFD);

    int queue = -1;
    int originalFlags = -1;
    int originalLowWater = 0;
    int originalNoSigPipe = 0;
    BOOL flagsChanged = NO, lowWaterChanged = NO, noSigPipeChanged = NO;
    NSUInteger sentPackets = 0, drainedPackets = 0, sentBytes = 0;
    uint64_t sentSamples = 0, drainedSamples = 0, sourceSamples = 0, generatedSamples = 0;
    uint64_t sentRTPSamples = 0;
#if SONOFERRY_LDAC_PROBE_ONLY
    uint64_t targetSamples = (uint64_t)seconds * profile.sampleRate;
    const BOOL continuous = seconds == 0;
#else
    uint64_t targetSamples = 0;
    const BOOL continuous = YES;
#endif
    probe.pcmContinuous = continuous;
    probe.pcmReserveBytes = profile.prefillBytes;
    probe.catchup = (CatchupState){0};
    probe.pcmCanSkip = YES;
    BOOL finishing = NO;
    probe.gain = gain;
    probe.targetGain = gain;
    probe.gainAckReady = YES;
    BOOL flushed = NO;
    unsigned int flushCalls = 0;
    float pcm[256];
    uint8_t packet[LDACBT_MAX_NBYTES + 13];
    RecoveryState recovery = {0};
    BOOL limitStopped = NO;
    double lastLatenessAt = 0;
    double started = 0;
    do {
        if (probe.closed || probe.failed || fd < 0) break;
        int socketType = 0;
        if (!ReadOption(fd, SO_TYPE, &socketType) || socketType != SOCK_STREAM ||
            !ReadOption(fd, SO_SNDLOWAT, &originalLowWater) ||
            !ReadOption(fd, SO_NOSIGPIPE, &originalNoSigPipe)) break;
        int noSigPipe = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe)) != 0) break;
        noSigPipeChanged = YES;
        originalFlags = fcntl(fd, F_GETFL);
        if (originalFlags < 0 || fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) != 0) break;
        flagsChanged = YES;
        queue = kqueue();
        if (queue < 0) break;
        struct kevent change, event;
        struct timespec immediate = {0, 0};
        EV_SET(&change, fd, EVFILT_WRITE, EV_ADD | EV_ENABLE, 0, 0, NULL);
        if (kevent(queue, &change, 1, &event, 1, &immediate) != 1 ||
            event.flags & (EV_ERROR | EV_EOF) || event.data <= 0 || event.data > INT_MAX) break;
        double initialPollAt = MonotonicTime();
        int baseline = (int)event.data;
        if (setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &baseline, sizeof(baseline)) != 0) break;
        lowWaterChanged = YES;
        printf("SOCKET fd=%d CID=%04X outgoingMTU=%u type=%d baseline=%d\n",
               fd, owned.cid, owned.outgoingMTU, socketType, baseline);
        started = MonotonicTime();
        double deadline = continuous ? INFINITY : started + seconds + 1;
        double nextProgress = started + 1;
        double lastPollAt = initialPollAt;
        int lastPollCount = 1;
        unsigned int lastPollFlags = event.flags;
        long lastPollData = (long)event.data;
        printf("LIVE_BEGIN gain=%.17g seconds=%u targetSamples=%llu bufferedFrames=%lu reserveFrames=%lu\n",
               gain, seconds, targetSamples, probe.pcmBytes / 8, probe.pcmReserveBytes / 8);
        SenderTiming timing = NewSenderTiming();
        while (YES) {
            RecordSenderStage(&timing, SenderControl);
            PollLiveControls(probe);
            RecordSenderStage(&timing, SenderOther);
            if (probe.closed || probe.failed || probe.inputEnded) break;
            if (probe.stopRequested) { finishing = YES; targetSamples = sourceSamples; }
#if SONOFERRY_LDAC_PROBE_ONLY
            else if (!continuous && sourceSamples == targetSamples) finishing = YES;
#endif
            if (finishing && !sourceSamples) { flushed = YES; break; }
            if (sourceSamples > UINT64_MAX - 2048 || generatedSamples > UINT64_MAX - 2048 ||
                probe.pcmSkippedBytes / 8 > UINT64_MAX - generatedSamples - 2048 || sentPackets == NSUIntegerMax) {
                printf("ENCODER_FAILED reason=sample-counter-overflow\n");
                break;
            }
            probe.pcmCanSkip = !finishing && sourceSamples == generatedSamples;
            double due = PacketDue(started, generatedSamples + probe.pcmSkippedBytes / 8, profile);
            if (continuous && !finishing) {
                RecordSenderStage(&timing, SenderPCM);
                [probe pollPCM];
                RecordSenderStage(&timing, SenderOther);
                double now = MonotonicTime();
                if ([probe recoverCatchupAt:now due:due]) RecordBreach(&recovery, now);
                due = PacketDue(started, generatedSamples + probe.pcmSkippedBytes / 8, profile);
                if (probe.failed) break;
            }
            if (!finishing) {
                NSUInteger inputFrames = continuous ? 128 : MIN((uint64_t)128, targetSamples - sourceSamples);
                NSUInteger requiredBytes = inputFrames * 8;
                adaptiveSourceReady &= probe.pcmBytes >= requiredBytes;
                BOOL underflowBreached = NO;
                while (probe.pcmBytes < requiredBytes && !probe.closed && !probe.failed && !probe.inputEnded && !probe.stopRequested &&
                       MonotonicTime() < due + 0.25 && MonotonicTime() < deadline) {
                    RecordSenderStage(&timing, SenderControl);
                    PollLiveControls(probe);
                    RecordSenderStage(&timing, SenderInput);
                    [probe pollInput];
                    RecordSenderStage(&timing, SenderPCM);
                    [probe pollPCM];
                    RecordSenderStage(&timing, SenderOther);
                    double now = MonotonicTime();
                    if (probe.pcmBytes < requiredBytes && now - due >= 0.1 && !underflowBreached) {
                        underflowBreached = YES;
                        BOOL first = RecordBreach(&recovery, now);
                        double pollAt = MonotonicTime();
                        int count = kevent(queue, NULL, 0, &event, 1, &immediate);
                        int pollError = count < 0 ? errno : 0;
                        now = MonotonicTime();
                        printf("PCM_BREACH sourceSamples=%llu late=%.6f first=%d strictPass=0 lastPoll=%.6f wakeGap=%.6f pollDuration=%.6f previousCount=%d previousFlags=%04X previousData=%ld count=%d flags=%04X data=%ld errno=%d\n",
                               sourceSamples, now - due, first, lastPollAt - started, pollAt - lastPollAt, now - pollAt,
                               lastPollCount, lastPollFlags, lastPollData, count, count > 0 ? event.flags : 0,
                               count > 0 ? (long)event.data : 0, pollError);
                        lastPollAt = now;
                        lastPollCount = count;
                        lastPollFlags = count > 0 ? event.flags : 0;
                        lastPollData = count > 0 ? (long)event.data : 0;
                        lastLatenessAt = now;
                        if (count < 0 || (count && (event.flags & (EV_ERROR | EV_EOF) || event.data != baseline))) {
                            probe.failed = YES;
                            break;
                        }
                    }
                    RecordSenderStage(&timing, SenderPacing);
                    RunLoopFor(0.001);
                    RecordSenderStage(&timing, SenderOther);
                }
                if (probe.stopRequested) continue;
                if (probe.pcmBytes < requiredBytes || probe.closed || probe.failed || probe.inputEnded) {
                    limitStopped = !probe.closed && !probe.failed && !probe.inputEnded;
                    if (limitStopped) {
                        double pollAt = MonotonicTime();
                        int count = kevent(queue, NULL, 0, &event, 1, &immediate);
                        double now = MonotonicTime();
                        RecordBreach(&recovery, now);
                        lastLatenessAt = now;
                        printf("PCM_LIMIT sourceSamples=%llu late=%.6f strictPass=0 lastPoll=%.6f wakeGap=%.6f pollDuration=%.6f count=%d flags=%04X data=%ld errno=%d\n",
                               sourceSamples, now - due, lastPollAt - started, pollAt - lastPollAt, now - pollAt, count,
                               count > 0 ? event.flags : 0, count > 0 ? (long)event.data : 0, count < 0 ? errno : 0);
                    }
                    printf("PCM_UNDERFLOW sourceSamples=%llu bufferedBytes=%lu late=%.6f limitStopped=%d\n",
                           sourceSamples, probe.pcmBytes, MonotonicTime() - due, limitStopped);
                    break;
                }
                BOOL wasRamping = probe.gainRampRemaining > 0;
                double currentGain = probe.gain;
                uint32_t rampRemaining = probe.gainRampRemaining;
                RecordSenderStage(&timing, SenderEncode);
                if (!ConvertRampedPCM(probe.pcmRing + probe.pcmHead, inputFrames, &currentGain, probe.targetGain, &rampRemaining, pcm)) {
                    printf("PCM_FAILED reason=nonfinite sourceSamples=%llu gain=%.17g\n", sourceSamples, currentGain);
                    probe.failed = YES;
                    break;
                }
                probe.gain = currentGain;
                probe.gainRampRemaining = rampRemaining;
                if (wasRamping && !rampRemaining) probe.gainAckReady = YES;
            }
            int frames = 0;
            BOOL flushing = finishing;
            if (flushing && ++flushCalls > 16) { printf("ENCODER_FAILED reason=flush-limit\n"); break; }
            NSUInteger packetLength = 0;
            LDACFrameFormat packetFormat = {profile.frameBytes, profile.bitrateKbps};
            uint64_t timestamp = generatedSamples + probe.pcmSkippedBytes / 8;
            RecordSenderStage(&timing, SenderEncode);
            if (!EncodePacket(probe.encoder, profile, flushing ? NULL : pcm, sentPackets, timestamp,
                    owned.outgoingMTU, (NSUInteger)baseline, packet, &packetLength, &frames, &packetFormat)) break;
            RecordSenderStage(&timing, SenderOther);
            if (!flushing) {
                NSUInteger inputFrames = continuous ? 128 : MIN((uint64_t)128, targetSamples - sourceSamples);
                probe.pcmHead = (probe.pcmHead + inputFrames * 8) % profile.capacityBytes;
                probe.pcmBytes -= inputFrames * 8;
                sourceSamples += inputFrames;
            }
            uint64_t packetSamples = (uint64_t)frames * profile.frameSamples;
            probe.pcmCanSkip = continuous && !finishing && sourceSamples == generatedSamples + packetSamples;
            if (!packetLength) {
                if (flushing) { flushed = YES; break; }
                RecordSenderStage(&timing, SenderControl);
                PollLiveControls(probe);
                RecordSenderStage(&timing, SenderPCM);
                [probe pollPCM];
                RecordSenderStage(&timing, SenderOther);
                continue;
            }
            if (finishing && generatedSamples + packetSamples > EncodedSampleLimit(targetSamples, profile)) {
                printf("ENCODER_FAILED reason=flush-padding generatedSamples=%llu frames=%d targetSamples=%llu\n",
                       generatedSamples, frames, targetSamples);
                break;
            }
            generatedSamples += packetSamples;
            probe.pcmCanSkip = NO;
            while (!probe.closed && !probe.failed && !probe.inputEnded && MonotonicTime() < due && MonotonicTime() < deadline) {
                RecordSenderStage(&timing, SenderControl);
                PollLiveControls(probe);
                RecordSenderStage(&timing, SenderInput);
                [probe pollInput];
                RecordSenderStage(&timing, SenderPCM);
                [probe pollPCM];
                RecordSenderStage(&timing, SenderPacing);
                RunLoopFor(0.001);
                RecordSenderStage(&timing, SenderOther);
            }
            double now = MonotonicTime();
            double lateness = now - due;
            if (probe.closed || probe.failed || probe.inputEnded || owned.socketFD != fd || now >= deadline) {
                limitStopped = now >= deadline;
                printf("PACING_STOP packet=%lu late=%.6f\n", sentPackets, lateness);
                break;
            }
            if (lateness >= 0.1) {
                BOOL first = RecordBreach(&recovery, now);
                double pollAt = MonotonicTime();
                int count = kevent(queue, NULL, 0, &event, 1, &immediate);
                int pollError = count < 0 ? errno : 0;
                now = MonotonicTime();
                RecordSenderStage(&timing, SenderOther);
                printf("PACING_BREACH packet=%lu late=%.6f elapsed=%.6f first=%d strictPass=0 lastPoll=%.6f wakeGap=%.6f pollDuration=%.6f previousCount=%d previousFlags=%04X previousData=%ld count=%d flags=%04X data=%ld errno=%d controlWall=%.6f controlCPU=%.6f inputWall=%.6f inputCPU=%.6f pcmWall=%.6f pcmCPU=%.6f encodeWall=%.6f encodeCPU=%.6f pacingWall=%.6f pacingCPU=%.6f pacingMax=%.6f otherWall=%.6f otherCPU=%.6f\n",
                       sentPackets, now - due, now - started, first, lastPollAt - started, pollAt - lastPollAt,
                       now - pollAt, lastPollCount, lastPollFlags, lastPollData, count,
                       count > 0 ? event.flags : 0, count > 0 ? (long)event.data : 0, pollError,
                       timing.wall[SenderControl], timing.cpu[SenderControl], timing.wall[SenderInput], timing.cpu[SenderInput],
                       timing.wall[SenderPCM], timing.cpu[SenderPCM], timing.wall[SenderEncode], timing.cpu[SenderEncode],
                       timing.wall[SenderPacing], timing.cpu[SenderPacing], timing.maximumPacing,
                       timing.wall[SenderOther], timing.cpu[SenderOther]);
                lastPollAt = now;
                lastPollCount = count;
                lastPollFlags = count > 0 ? event.flags : 0;
                lastPollData = count > 0 ? (long)event.data : 0;
                lateness = now - due;
                if (count < 0 || (count && (event.flags & (EV_ERROR | EV_EOF) || event.data != baseline))) break;
            }
            lastLatenessAt = now;
            if (!probe.pcmSkippedBytes && RecordRecovery(&recovery, now, lateness))
                printf("RECOVERY packet=%lu late=%.6f elapsed=%.6f sinceFirstBreach=%.6f strictPass=0\n",
                       sentPackets, lateness, now - started, now - recovery.firstBreach);
#if SONOFERRY_LDAC_PROBE_ONLY
            if ((!continuous && lateness >= 0.25) || now >= deadline) {
                limitStopped = YES;
                printf("PACING_LIMIT packet=%lu late=%.6f elapsed=%.6f limit=0.250\n", sentPackets, lateness, now - started);
                break;
            }
#endif
            double beforeSend = MonotonicTime();
            ssize_t sent = send(fd, packet, packetLength, 0);
            double afterSend = MonotonicTime();
            double drainLimit = continuous ? probe.profile.catchupLimit + 1.0 : 0.25;
            if (!continuous || sent != (ssize_t)packetLength) printf("SEND packet=%lu CID=%04X bytes=%zd expected=%lu elapsed=%.6f duration=%.6f late=%.6f errno=%d\n",
                   sentPackets, owned.cid, sent, packetLength, afterSend - started, afterSend - beforeSend, lateness,
                   sent < 0 ? errno : 0);
            if (sent != (ssize_t)packetLength) break;
            sentPackets++;
            sentBytes += (NSUInteger)sent;
            sentSamples += packet[12] * profile.frameSamples;
            sentRTPSamples = timestamp + packet[12] * profile.frameSamples;
            BOOL drained = NO;
            BOOL drainBreached = NO;
            double lastDrainObservation = afterSend;
            double maximumSchedulerGap = 0;
            while (!probe.closed && !probe.failed && !probe.inputEnded && owned.socketFD == fd) {
                [probe observeCatchupAt:MonotonicTime() due:PacketDue(started, generatedSamples + probe.pcmSkippedBytes / 8, profile) enabled:!finishing];
                double pollAt = MonotonicTime();
                maximumSchedulerGap = fmax(maximumSchedulerGap, pollAt - lastDrainObservation);
                double previousPollAt = lastPollAt;
                double wakeGap = pollAt - lastPollAt;
                int count = kevent(queue, NULL, 0, &event, 1, &immediate);
                int pollError = count < 0 ? errno : 0;
                now = MonotonicTime();
                lastDrainObservation = now;
                double drainDuration = now - afterSend;
                if (drainDuration >= 0.1 && !drainBreached) {
                    drainBreached = YES;
                    BOOL first = RecordBreach(&recovery, now);
                    printf("DRAIN_BREACH packet=%lu elapsed=%.6f duration=%.6f first=%d strictPass=0 lastPoll=%.6f wakeGap=%.6f pollDuration=%.6f previousCount=%d previousFlags=%04X previousData=%ld count=%d flags=%04X data=%ld errno=%d\n",
                           sentPackets - 1, now - started, drainDuration, first, lastPollAt - started, pollAt - lastPollAt,
                           now - pollAt, lastPollCount, lastPollFlags, lastPollData, count,
                           count > 0 ? event.flags : 0, count > 0 ? (long)event.data : 0, pollError);
                }
                lastPollAt = now;
                lastPollCount = count;
                lastPollFlags = count > 0 ? event.flags : 0;
                lastPollData = count > 0 ? (long)event.data : 0;
                if (count < 0 || (count && event.flags & (EV_ERROR | EV_EOF))) {
                    printf("DRAIN_ERROR packet=%lu count=%d flags=%04X data=%ld errno=%d\n",
                           sentPackets - 1, count, lastPollFlags, lastPollData, pollError);
                    break;
                }
                if (count) {
                    if (!continuous) printf("DRAIN packet=%lu writable=%ld baseline=%d elapsed=%.6f duration=%.6f flags=%04X wakeGap=%.6f\n",
                           sentPackets - 1, (long)event.data, baseline, now - started, drainDuration, event.flags,
                           wakeGap);
                    if (event.data == baseline) drained = YES;
                }
                if (continuous) drainLimit = fmax(drainLimit, probe.profile.catchupLimit + 1.0);
                if (drainDuration >= drainLimit || now >= deadline) {
                    limitStopped = YES;
                    printf("DRAIN_LIMIT packet=%lu elapsed=%.6f duration=%.6f limit=%.3f lastPoll=%.6f wakeGap=%.6f pollDuration=%.6f count=%d flags=%04X data=%ld\n",
                           sentPackets - 1, now - started, drainDuration, drainLimit, previousPollAt - started, wakeGap, now - pollAt,
                           lastPollCount, lastPollFlags, lastPollData);
                    break;
                }
                if (count) break;
                PollLiveControls(probe);
                if (probe.stopRequested) break;
                [probe pollInput];
                [probe pollPCM];
                RunLoopFor(0.001);
            }
            if (drained) {
                timing = NewSenderTiming();
                drainedPackets++;
                drainedSamples = sentSamples;
                if (drainedPackets == 1) printf("LIVE_SENT packets=1 rate=%u channels=2 bitrateKbps=%d eqmid=%d\n",
                    profile.sampleRate, packetFormat.bitrateKbps, profile.eqmid);
                else if (profile.adaptive && packetFormat.frameBytes != transmittedFormat.frameBytes)
                    printf("LIVE_FORMAT rate=%u channels=2 bitrateKbps=%d frameBytes=%d\n",
                           profile.sampleRate, packetFormat.bitrateKbps, packetFormat.frameBytes);
                transmittedFormat = packetFormat;
                if (probe.gainAckReady) {
                    printf("GAIN_APPLIED gain=%.17g\n", probe.targetGain);
                    probe.gainAckReady = NO;
                }
                if (now >= nextProgress) {
                    printf("LIVE_PROGRESS sentPackets=%lu drainedPackets=%lu sourceSamples=%llu sentSamples=%llu drainedSamples=%llu bufferedFrames=%lu late=%.6f elapsed=%.6f strictPass=%d skippedFrames=%llu rtpSamples=%llu catchupSeconds=%.6f\n",
                           sentPackets, drainedPackets, sourceSamples, sentSamples, drainedSamples, probe.pcmBytes / 8,
                           lateness, now - started, !recovery.breached && !probe.pcmSkippedBytes, probe.pcmSkippedBytes / 8,
                           sentRTPSamples, probe.catchup.elapsed);
                    nextProgress = now + 1;
                }
                if (profile.adaptive && !finishing && !probe.stopRequested) {
                    int priority = LDACAdaptivePolicyObserve(&adaptivePolicy, ldacBT_get_eqmid(probe.encoder),
                        (double)packetSamples / profile.sampleRate, now - beforeSend, maximumSchedulerGap,
                        lateness, adaptiveSourceReady && adaptiveSkippedBytes == probe.pcmSkippedBytes);
                    if (priority) {
                        if (ldacBT_alter_eqmid_priority(probe.encoder, priority) != 0) {
                            printf("ENCODER_FAILED reason=adaptive-quality code=%d\n", ldacBT_get_error_code(probe.encoder));
                            probe.failed = YES;
                        } else {
                            printf("ADAPTIVE_TARGET packet=%lu priority=%d eqmid=%d writeAndDrain=%.6f schedulerGap=%.6f late=%.6f\n",
                                   sentPackets - 1, priority, ldacBT_get_eqmid(probe.encoder),
                                   now - beforeSend, maximumSchedulerGap, lateness);
                        }
                    }
                }
                adaptiveSourceReady = YES;
                adaptiveSkippedBytes = probe.pcmSkippedBytes;
            }
            if (probe.stopRequested && !probe.failed && !probe.closed && !probe.inputEnded) { result = 0; break; }
            if (!drained || limitStopped) { printf("DRAIN_STOP packet=%lu elapsed=%.6f\n", sentPackets - 1, MonotonicTime() - started); break; }
        }
        if (!probe.closed && !probe.failed && !probe.inputEnded && !limitStopped && flushed && sourceSamples == targetSamples && generatedSamples == sentSamples && drainedPackets == sentPackets)
            result = 0;
    } while (NO);
    probe.pcmComplete = YES;
    if (started) {
        double postroll = fmin(continuous ? INFINITY : started + seconds + 1, MonotonicTime() + 0.5);
        while (!probe.closed && !probe.failed && MonotonicTime() < postroll) {
            PollLiveControls(probe);
            [probe pollInput];
            [probe pollPCM];
            RunLoopFor(0.001);
        }
    }
    if (!probe.closed && owned.socketFD == fd) {
        if (lowWaterChanged && setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &originalLowWater, sizeof(originalLowWater)) != 0)
            result = 5;
        if (noSigPipeChanged && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &originalNoSigPipe, sizeof(originalNoSigPipe)) != 0)
            result = 5;
        if (flagsChanged && fcntl(fd, F_SETFL, originalFlags) != 0) result = 5;
    }
    if (queue >= 0) close(queue);
    if (probe.closed || probe.failed || probe.inputEnded) result = 5;
    double recoveryObserved = recovery.breached ? fmax(0, lastLatenessAt - recovery.firstBreach) : 0;
    int recoveredWithinOneSecond = recovery.recovered ? 1 : (recovery.breached && recoveryObserved >= 1 ? 0 : -1);
    printf("FEED_COMPLETE result=%d strictPass=%d sentPackets=%lu drainedPackets=%lu sentBytes=%lu sentSamples=%llu drainedSamples=%llu sourceSamples=%llu generatedSamples=%llu targetSamples=%llu pcmReadBytes=%llu pcmDiscardedBytes=%llu bufferedFrames=%lu elapsed=%.6f closed=%d firstBreachElapsed=%.6f recoveredWithin1s=%d recoveryObservedSeconds=%.6f recoveryElapsed=%.6f limitStopped=%d skippedFrames=%llu rtpSamples=%llu paddingSamples=%llu\n",
           result, result == 0 && !recovery.breached && !probe.pcmSkippedBytes, sentPackets, drainedPackets, sentBytes, sentSamples, drainedSamples,
           sourceSamples, generatedSamples, targetSamples, probe.pcmReadBytes, probe.pcmDiscardedBytes, probe.pcmBytes / 8,
           started ? MonotonicTime() - started : 0, probe.closed,
           recovery.breached ? recovery.firstBreach - started : -1, recoveredWithinOneSecond, recoveryObserved,
           recovery.recovered ? recovery.recoveryTime - recovery.firstBreach : -1, limitStopped,
           probe.pcmSkippedBytes / 8, sentRTPSamples, generatedSamples >= sourceSamples ? generatedSamples - sourceSamples : 0);
    [NSProcessInfo.processInfo endActivity:activity];
    return result == 0;
}

#include "LHDCLive.inc"
#include "../../Tests/Native/LHDCRecoveryTests.inc"
#include "../../Tests/Native/LHDCSenderTests.inc"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--sender-self-test") == 0) return LHDCSenderChecks() ? 0 : 1;
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) {
            BOOL passed = SelfTest() && LHDCRecoveryChecks();
            printf("offline recovery/PCM checks=%s\n", passed ? "PASS" : "FAIL");
            return passed ? 0 : 1;
        }
        uint32_t pcmDescriptor = 0;
        uint32_t sampleRate = 48000;
        uint32_t catchupLimitMs = 5000, prefillMs = 250;
        BOOL catchupSeen = NO, prefillSeen = NO, awaitPrepare = NO;
        NSString *quality = @"low";
        NSString *address = nil;
        BOOL pcmSeen = NO, addressSeen = NO, rateSeen = NO, qualitySeen = NO;
        BOOL lhdc = NO; unsigned bits = 24, endpoint = 0, minimum = 64, maximum = 1000, fixedBitrate = 0;
        BOOL argumentsValid = argc >= 4 && strcmp(argv[1], "--media") == 0;
        for (int index = 2; argumentsValid && index < argc; index++) {
            if (!strcmp(argv[index], "--await-prepare") && !awaitPrepare) {
                awaitPrepare = YES;
            } else if (!strcmp(argv[index], "--pcm-fd") && !pcmSeen && index + 1 < argc) {
                argumentsValid = ParseUnsigned([NSString stringWithUTF8String:argv[++index]], &pcmDescriptor) &&
                    pcmDescriptor > 2 && pcmDescriptor <= INT_MAX;
                pcmSeen = YES;
            } else if (!strcmp(argv[index], "--address") && !addressSeen && index + 1 < argc) {
                address = NormalizeAddress(argv[++index]);
                addressSeen = YES;
                argumentsValid = address != nil;
            } else if (!strcmp(argv[index], "--sample-rate") && !rateSeen && index + 1 < argc) {
                argumentsValid = ParseUnsigned([NSString stringWithUTF8String:argv[++index]], &sampleRate);
                rateSeen = YES;
            } else if (!strcmp(argv[index], "--quality") && !qualitySeen && index + 1 < argc) {
                quality = [NSString stringWithUTF8String:argv[++index]];
                qualitySeen = YES;
            } else if (!strcmp(argv[index], "--catchup-limit-ms") && !catchupSeen && index + 1 < argc) {
                argumentsValid = ParseUnsigned([NSString stringWithUTF8String:argv[++index]], &catchupLimitMs); catchupSeen = YES;
            } else if (!strcmp(argv[index], "--prefill-ms") && !prefillSeen && index + 1 < argc) {
                argumentsValid = ParseUnsigned([NSString stringWithUTF8String:argv[++index]], &prefillMs); prefillSeen = YES;
            } else if (!strcmp(argv[index], "--codec") && index + 1 < argc) {
                const char *codec = argv[++index]; lhdc = !strcmp(codec, "lhdcV5"); argumentsValid = lhdc || !strcmp(codec, "ldac");
            } else if (index + 1 < argc && (!strcmp(argv[index], "--bits") || !strcmp(argv[index], "--endpoint") || !strcmp(argv[index], "--min-bitrate") || !strcmp(argv[index], "--max-bitrate") || !strcmp(argv[index], "--bitrate"))) {
                const char *key = argv[index++]; char *end = NULL; unsigned long value = strtoul(argv[index], &end, 10);
                argumentsValid = *argv[index] && !*end && value <= 1000;
                if (!strcmp(key, "--bits")) bits = (unsigned)value;
                if (!strcmp(key, "--endpoint")) endpoint = (unsigned)value;
                if (!strcmp(key, "--min-bitrate")) minimum = (unsigned)value;
                if (!strcmp(key, "--max-bitrate")) maximum = (unsigned)value;
                if (!strcmp(key, "--bitrate")) fixedBitrate = (unsigned)value;
            } else argumentsValid = NO;
        }
        LDACProfile profile;
        argumentsValid = argumentsValid && pcmSeen && addressSeen && (bits == 16 || bits == 24) && endpoint <= 62 && minimum <= maximum;
        argumentsValid &= SelectProfile(lhdc ? 48000 : sampleRate, quality, &profile);
        if (lhdc) {
            argumentsValid &= sampleRate == 44100 || sampleRate == 48000 || sampleRate == 96000 || sampleRate == 192000;
            unsigned wanted = fixedBitrate ?: ([quality isEqualToString:@"high"] ? 1000 : [quality isEqualToString:@"mid"] ? (sampleRate == 44100 ? 480 : 500) : 400);
            int bitrate = 0;
            for (unsigned i = 0; i < 9; i++) { unsigned value = MacLHDCBitrate(sampleRate, i); if (value >= minimum && value <= maximum && value <= wanted) bitrate = value; }
            argumentsValid &= bitrate > 0;
            profile.sampleRate = sampleRate; profile.bitrateKbps = bitrate;
            profile.gainRampFrames = sampleRate / 50;
        }
        if (argumentsValid) argumentsValid = ConfigureBuffering(&profile, catchupLimitMs, prefillMs);
        if (fixedBitrate) {
            unsigned rates[] = {64,160,192,sampleRate == 44100 ? 240 : 256,320,400,sampleRate == 44100 ? 480 : 500,900,1000};
            BOOL found = NO;
            for (unsigned i = 0; i < 9; i++) found |= rates[i] == fixedBitrate;
            argumentsValid &= lhdc && ![quality isEqualToString:@"auto"] && found && fixedBitrate >= minimum && fixedBitrate <= maximum;
        }
        if (!argumentsValid) {
#if SONOFERRY_LDAC_PROBE_ONLY
            fprintf(stderr, "Usage: %s --media --pcm-fd FD --address ADDRESS [--sample-rate 44100|48000|88200|96000] [--quality auto|low|mid|high]; stdin: open, start live GAIN SECONDS (0=continuous, 1..60), gain VALUE, stop, close, transport-closed\n"
#else
            fprintf(stderr, "Usage: %s --media --pcm-fd FD --address ADDRESS [--sample-rate 44100|48000|88200|96000] [--quality auto|low|mid|high]; stdin: open, start live GAIN 0, gain VALUE, stop, close, transport-closed\n"
#endif
                    "       %s --self-test\n", argv[0], argv[0]);
            return 2;
        }
        struct stat pipeInfo;
        int pcmFlags = fcntl((int)pcmDescriptor, F_GETFL);
        if (pcmFlags < 0 || (pcmFlags & O_ACCMODE) != O_RDONLY || fstat((int)pcmDescriptor, &pipeInfo) != 0 ||
            !S_ISFIFO(pipeInfo.st_mode) || fcntl((int)pcmDescriptor, F_SETFL, pcmFlags | O_NONBLOCK) != 0) {
            fprintf(stderr, "PCM_FAILED reason=invalid-read-pipe fd=%u errno=%d\n", pcmDescriptor, errno);
            return 2;
        }
        if (!LDACWatchParent(20)) return 3;
        setbuf(stdout, NULL);
        DirectMediaProbe *probe __attribute__((objc_precise_lifetime)) = [DirectMediaProbe new];
        probe.profile = profile;
        probe.controlPending = [NSMutableData data];
        probe.pcmFD = (int)pcmDescriptor;
        probe.pcmRing = malloc(profile.capacityBytes);
        if (!probe.pcmRing) { printf("PCM_FAILED reason=allocation\n"); return 4; }
        // Load the process and allocate its buffer before reconnecting. Do not
        // obtain an IOBluetooth peer until the engine has observed the new ACL.
        if (awaitPrepare) {
            printf("MEDIA_WAITING_FOR_ACL\n");
            NSString *preparation = ReadCommand(probe);
            if ([preparation isEqualToString:@"close"]) return 0;
            if (![preparation isEqualToString:@"prepare"]) return 4;
        }
        IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
        printf("BEFORE time=%.6f address=%s paired=%d connected=%d\n", NSDate.date.timeIntervalSince1970,
               device.addressString.UTF8String, device.isPaired, ClassicIsConnected(device));
        if (!device || !device.isPaired || !ClassicIsConnected(device)) {
            fprintf(stderr, "The selected Bluetooth target must already be paired and connected; launch only after signaling Open acceptance\n");
            return 3;
        }
        CBClassicPeer *peer __attribute__((objc_precise_lifetime)) = device.classicPeer;
        if (!peer) {
            printf("NO_OPEN coordinator returned no Classic peer\n");
            return 4;
        }
        printf("TARGET owner=IOBluetoothCoordinator address=%s UUID=%s\n", device.addressString.UTF8String,
               peer.identifier.UUIDString.UTF8String);
        printf("BUFFER_POLICY catchupLimitMs=%u prefillMs=%u storageFrames=%lu\n", catchupLimitMs, prefillMs, profile.capacityBytes / 8);
        printf("MEDIA_PREPARED\n");
        NSString *opening = ReadCommand(probe);
        if ([opening isEqualToString:@"close"]) return 0;
        if (![opening isEqualToString:@"open"]) return 4;
        __block BOOL openDone = NO;
        __block NSInteger openError = 0;
        peer.connectL2CAPCallback = ^(CBL2CAPChannel *value, NSInteger error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                printf("OPEN_CALLBACK time=%.6f status=0x%08X channel=%p PSM=%04X CID=%04X\n",
                       NSDate.date.timeIntervalSince1970, (unsigned int)error, (__bridge void *)value, value.PSM, value.cid);
                if (openDone || (value && value.PSM != 0x0019)) {
                    probe.failed = YES;
                    openError = -1;
                    openDone = YES;
                    return;
                }
                probe.channel = value;
                probe.realCID = value.cid;
                openError = error;
                openDone = YES;
                if (error) { probe.failed = YES; probe.openFailed = YES; }
            });
        };
        peer.disconnectL2CAPCallback = ^(CBL2CAPChannel *value, NSInteger error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                printf("CLOSED_CALLBACK time=%.6f channel=%p PSM=%04X CID=%04X status=0x%08X\n",
                       NSDate.date.timeIntervalSince1970, (__bridge void *)value, value.PSM, value.cid, (unsigned int)error);
                if (probe.channel && value && value.PSM == 0x0019 && value.cid == probe.realCID)
                    probe.closed = YES;
            });
        };
        void (^ownedOpenCallback)(CBL2CAPChannel *, NSInteger) = peer.connectL2CAPCallback;
        void (^ownedCloseCallback)(CBL2CAPChannel *, NSInteger) = peer.disconnectL2CAPCallback;
        printf("OPEN_BEGIN time=%.6f PSM=0019 role=media\n", NSDate.date.timeIntervalSince1970);
        [peer openL2CAPChannel:0x0019];
        double openDeadline = MonotonicTime() + 5;
        while (!openDone && !probe.stdinEnded && !probe.closeRequested && MonotonicTime() < openDeadline) {
            if (peer.connectL2CAPCallback != ownedOpenCallback || peer.disconnectL2CAPCallback != ownedCloseCallback) {
                printf("CALLBACK_REPLACED phase=open\n");
                peer.connectL2CAPCallback = ownedOpenCallback;
                peer.disconnectL2CAPCallback = ownedCloseCallback;
            }
            NSString *command = AvailableCommand(probe);
            if ([command isEqualToString:@"close"] || [command isEqualToString:@"stop"]) probe.closeRequested = YES;
            else if (command) { printf("COMMAND_REJECTED phase=open\n"); probe.failed = YES; }
            RunLoopFor(0.001);
        }
        BOOL openExpired = !openDone;
        if (openExpired) {
            printf("OPEN_DEADLINE no sends; retaining owner until terminal open callback\n");
            while (!openDone && !probe.stdinEnded && !probe.closeRequested) {
                NSString *command = AvailableCommand(probe);
                if ([command isEqualToString:@"close"] || [command isEqualToString:@"stop"]) probe.closeRequested = YES;
                else if (command) { printf("COMMAND_REJECTED phase=open\n"); probe.failed = YES; }
                RunLoopFor(0.001);
            }
            if (!openDone) {
                printf("PENDING_CLOSE_REQUESTED parentEOF=%d\n", probe.stdinEnded);
                [peer closeL2CAPChannel:0x0019];
                double deadline = MonotonicTime() + 2;
                while (!openDone && MonotonicTime() < deadline) RunLoopFor(0.001);
                if (!openDone) printf("OPEN_TERMINAL_UNCONFIRMED closeRequested=1\n");
            }
        }
        CBL2CAPChannel *owned __attribute__((objc_precise_lifetime)) = probe.channel;
        printf("OPEN_RETURN time=%.6f status=0x%08X channel=%p\n",
               NSDate.date.timeIntervalSince1970, (unsigned int)openError, (__bridge void *)owned);
        int result = 5;
        if (!openExpired && !openError && owned && !probe.closed && !probe.failed &&
            owned.PSM == 0x0019 && owned.cid && owned.outgoingMTU > 13) {
            probe.input = owned.inputStream;
            probe.output = owned.outputStream;
            [probe.input open];
            [probe.output open];
            if (lhdc) {
                probe.lhdcEncoder = calloc(1, sizeof(MacLHDC));
                unsigned requiredMTU = MacLHDCMinimumMTU(sampleRate, profile.bitrateKbps);
                if (requiredMTU > owned.outgoingMTU) {
                    printf("PCM_FAILED reason=lhdc-MTU required=%u actual=%u\n", requiredMTU, owned.outgoingMTU); probe.failed = YES;
                } else if (!probe.lhdcEncoder || !MacLHDCOpen(probe.lhdcEncoder, sampleRate, bits, profile.bitrateKbps, minimum, maximum, MIN(owned.outgoingMTU, 8206), arc4random())) {
                    printf("PCM_FAILED reason=lhdc-init-or-MTU\n"); probe.failed = YES;
                }
            } else {
                probe.encoder = ldacBT_get_handle();
                int encoderMTU = MIN((int)owned.outgoingMTU, 2570); probe.encoderMTU = encoderMTU;
                if (!probe.encoder || ldacBT_init_handle_encode(probe.encoder, encoderMTU, profile.eqmid, LDACBT_CHANNEL_MODE_STEREO, LDACBT_SMPL_FMT_F32, profile.sampleRate) != 0 || !EncoderMatchesProfile(probe.encoder, profile)) {
                    printf("PCM_FAILED reason=encoder-init\n"); probe.failed = YES;
                }
            }
            probe.pcmActive = !probe.failed;
            if (!probe.failed) printf("READY CID=%04X outgoingMTU=%u socketFD=%d PSM=0019 rate=%d channels=2 bitrateKbps=%d eqmid=%d\n",
                   owned.cid, owned.outgoingMTU, owned.socketFD, profile.sampleRate, profile.bitrateKbps, profile.eqmid);
            BOOL attempted = NO;
            BOOL feedSucceeded = NO;
            result = 0;
            while (YES) {
                NSString *command = ReadCommand(probe);
                if (!command) { result = probe.stdinEnded && feedSucceeded ? 0 : 5; break; }
                if ([command isEqualToString:@"stop"]) {
                    probe.stopRequested = YES;
                    printf("STOP_REQUESTED source=stdin waitingClose=1\n");
                    continue;
                }
                if ([command isEqualToString:@"close"]) {
                    if (probe.closed && !feedSucceeded) result = 5;
                    break;
                }
                if (!attempted && !probe.closed && !probe.failed && !probe.inputEnded && [command hasPrefix:@"start live "]) {
                    attempted = YES;
                    double gain = 0;
                    uint32_t seconds = 0;
                    NSArray<NSString *> *fields = [command componentsSeparatedByString:@" "];
                    BOOL valid = fields.count == 4 && ParseGain(fields[2], &gain) && ParseDurationSeconds(fields[3], &seconds) &&
                        probe.pcmReady;
                    feedSucceeded = valid && (lhdc ? FeedLHDC(probe, owned, gain, seconds) : FeedLive(probe, owned, gain, seconds));
                    if (!feedSucceeded) {
                        result = 5;
                        if (!valid) {
                            probe.pcmComplete = YES;
                            printf("FEED_COMPLETE result=5 strictPass=0 reason=invalid-start-or-prefill sentPackets=0 drainedPackets=0 sentBytes=0 sentSamples=0 drainedSamples=0 sourceSamples=0 generatedSamples=0 targetSamples=0\n");
                        }
                    }
                    printf("WAIT_CLOSE CID=%04X\n", owned.cid);
                    if (probe.closeRequested || probe.stdinEnded) break;
                } else {
                    printf("COMMAND_REJECTED attempted=%d failed=%d\n", attempted, probe.failed);
                    result = 5;
                }
            }
        } else {
            printf("NOT_READY status=0x%08X closed=%d failed=%d CID=%04X outgoingMTU=%u socketFD=%d\n",
                   (unsigned int)openError, probe.closed, probe.failed, owned.cid, owned.outgoingMTU, owned ? owned.socketFD : -1);
        }
        if (probe.openFailed || !owned) {
            if (openDone) printf("OPEN_FAILED_TERMINAL no established channel to close\n");
            else printf("OPEN_CLOSE_UNCONFIRMED no delivered channel; normal close requested\n");
        } else if (!probe.closed) {
            printf("CLOSE_BEGIN time=%.6f CID=%04X\n", NSDate.date.timeIntervalSince1970, owned.cid);
            [peer closeL2CAPChannel:0x0019];
            printf("CLOSE_RETURN time=%.6f requested=1\n", NSDate.date.timeIntervalSince1970);
            printf("WAIT_TRANSPORT_CLOSED CID=%04X\n", owned.cid);
            double closeDeadline = 0;
            while (!probe.closed) {
                NSString *command = AvailableCommand(probe);
                if ([command isEqualToString:@"transport-closed"]) {
                    probe.closed = YES;
                    printf("TRANSPORT_CLOSED_CONFIRMED time=%.6f CID=%04X source=daemon-gate\n",
                           NSDate.date.timeIntervalSince1970, owned.cid);
                } else if (command) {
                    printf("UNEXPECTED_TRANSPORT_CLOSE_CONTROL command=%s\n", command.UTF8String);
                    result = 5;
                }
                [probe pollInput];
                [probe pollPCM];
                if (probe.stdinEnded && probe.inputEnded && !probe.closed) {
                    probe.closed = YES;
                    printf("TRANSPORT_CLOSED_CONFIRMED time=%.6f CID=%04X source=owned-input-eof\n", NSDate.date.timeIntervalSince1970, owned.cid);
                }
                if (probe.stdinEnded && !closeDeadline) closeDeadline = MonotonicTime() + 2;
                if (closeDeadline && !probe.closed && MonotonicTime() >= closeDeadline) {
                    printf("TRANSPORT_CLOSE_UNCONFIRMED CID=%04X parentEOF=1 closeRequested=1\n", owned.cid);
                    result = 5;
                    break;
                }
                if (!probe.closed) RunLoopFor(0.001);
            }
        }
        [probe.input close];
        [probe.output close];
        peer.connectL2CAPCallback = nil;
        peer.disconnectL2CAPCallback = nil;
        printf("DELEGATE_CLEAR time=%.6f status=0x%08X\n", NSDate.date.timeIntervalSince1970, 0);
        if (probe.failed) result = 5;
        printf("AFTER time=%.6f result=%d CID=%04X closed=%d received=%lu paired=%d connected=%d\n",
               NSDate.date.timeIntervalSince1970, result, owned.cid, probe.closed, probe.received,
               device.isPaired, ClassicIsConnected(device));
        return result;
    }
}
