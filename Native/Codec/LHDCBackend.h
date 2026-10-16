// SonoFerry codec adapter. LHDC media layout follows Android 17 A2DP source.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "lhdcv5_enc.h"
typedef struct {
    lhdcv5_enc_t *encoder;
    uint32_t rate, bits, block, mtu, minimumIndex, maximumIndex, index;
    uint64_t consumed, emitted, skipped;
    uint16_t sequence;
    uint32_t ssrc;
    double gain, targetGain;
    uint32_t rampRemaining;
} MacLHDC;
int MacLHDCBitrate(uint32_t rate, unsigned index);
unsigned MacLHDCMinimumMTU(uint32_t rate, unsigned bitrate);
bool MacLHDCOpen(MacLHDC *codec, uint32_t rate, unsigned bits, unsigned bitrate, unsigned minimum, unsigned maximum, unsigned mtu, uint32_t ssrc);
void MacLHDCClose(MacLHDC *codec);
void MacLHDCGain(MacLHDC *codec, double gain);
bool MacLHDCAdjust(MacLHDC *codec, int direction);
// Discard stale, whole PCM blocks only when the encoder has no queued frames.
// Keeps bitrate, RTP sequence and SSRC; advances the media clock by skipped frames.
bool MacLHDCDiscontinuity(MacLHDC *codec, uint64_t skippedFrames);
// Exactly block stereo Float32 frames; returns a complete RTP+LHDC packet or length=0.
// No allocation or I/O. Timestamps advance by actual encoded sample counts.
bool MacLHDCEncode(MacLHDC *codec, const float *pcm, uint8_t *packet, size_t capacity, size_t *length, unsigned *bitrate);
