#include "LHDCBackend.h"
#include <math.h>
#include <string.h>

int MacLHDCBitrate(uint32_t rate, unsigned index) {
    const int rates[] = {64,160,192,rate == 44100 ? 240 : 256,320,400,rate == 44100 ? 480 : 500,900,1000};
    return index < 9 ? rates[index] : 0;
}
unsigned MacLHDCMinimumMTU(uint32_t rate, unsigned bitrate) {
    // Pinned V5 encoder: two independently rounded channel payloads, a 2-byte
    // frame header and our 14-byte RTP/media header. No media fragmentation.
    if ((rate != 44100 && rate != 48000 && rate != 96000 && rate != 192000) || bitrate > 1000 || bitrate < 64) return 0;
    return 16 + 2 * ((uint64_t)bitrate * 1000 * 50 / (rate == 44100 ? 147000 : 160000));
}
bool MacLHDCOpen(MacLHDC *c, uint32_t rate, unsigned bits, unsigned bitrate, unsigned minimum, unsigned maximum, unsigned mtu, uint32_t ssrc) {
    memset(c, 0, sizeof(*c));
    if ((rate != 44100 && rate != 48000 && rate != 96000 && rate != 192000) || (bits != 16 && bits != 24) || mtu < 314 || mtu > 8206 || minimum > maximum) return false;
    int selected = -1, low = -1, high = -1;
    for (unsigned i = 0; i < 9; i++) {
        unsigned value = MacLHDCBitrate(rate, i);
        if (value >= minimum && value <= maximum) { if (low < 0) low = i; high = i; if (value <= bitrate) selected = i; }
    }
    if (selected < 0 || MacLHDCMinimumMTU(rate, MacLHDCBitrate(rate, selected)) > mtu) return false;
    while (high > selected && MacLHDCMinimumMTU(rate, MacLHDCBitrate(rate, high)) > mtu) high--;
    c->rate = rate; c->bits = bits; c->mtu = mtu; c->ssrc = ssrc; c->index = selected; c->minimumIndex = low; c->maximumIndex = high;
    c->encoder = lhdcv5_enc_new(LHDC_VERSION_1);
    if (!c->encoder) return false;
    if (lhdcv5_enc_init_encoder(c->encoder, rate, bits, selected, mtu - 14, LHDC_ENC_INTERVAL_20MS) ||
        lhdcv5_enc_get_block_size(c->encoder, &c->block) || c->block > 960 || c->block < 240) { MacLHDCClose(c); return false; }
    return true;
}
void MacLHDCClose(MacLHDC *c) { if (c->encoder) lhdcv5_enc_free(c->encoder); c->encoder = NULL; }
void MacLHDCGain(MacLHDC *c, double gain) { if (isfinite(gain) && gain >= 0 && gain <= 1) { c->targetGain = gain; c->rampRemaining = c->rate / 50; } }
bool MacLHDCAdjust(MacLHDC *c, int direction) {
    if (direction != -1 && direction != 1) return false;
    int next = (int)c->index + direction;
    if (next < (int)c->minimumIndex || next > (int)c->maximumIndex) return true;
    if (lhdcv5_enc_set_bitrate_index(c->encoder, next, true)) return false;
    c->index = next; return true;
}
bool MacLHDCDiscontinuity(MacLHDC *c, uint64_t frames) {
    if (!c->encoder || !c->block || !frames || frames % c->block || c->consumed != c->emitted ||
        frames > UINT64_MAX - c->skipped || c->consumed > UINT64_MAX - c->skipped - frames) return false;
    if (lhdcv5_enc_init_encoder(c->encoder, c->rate, c->bits, c->index, c->mtu - 14, LHDC_ENC_INTERVAL_20MS)) return false;
    c->skipped += frames;
    // A short fade-in softens the discontinuity; the user's target is unchanged.
    c->gain = 0; c->rampRemaining = c->rate / 50;
    return true;
}
bool MacLHDCEncode(MacLHDC *c, const float *pcm, uint8_t *packet, size_t capacity, size_t *length, unsigned *bitrate) {
    if (!c->encoder || capacity < c->mtu || !pcm || c->skipped > UINT64_MAX - c->block ||
        c->consumed > UINT64_MAX - c->skipped - c->block) return false;
    *length = 0;
    uint8_t integerPCM[960 * 2 * 3];
    unsigned stride = c->bits / 8;
    double scale = c->bits == 16 ? 32768.0 : 8388608.0;
    for (unsigned frame = 0; frame < c->block; frame++) {
        if (c->rampRemaining) { c->gain += (c->targetGain - c->gain) / c->rampRemaining; if (!--c->rampRemaining) c->gain = c->targetGain; }
        for (unsigned ch = 0; ch < 2; ch++) {
            unsigned sample = frame * 2 + ch;
            if (!isfinite(pcm[sample])) return false;
            double value = fmax(-1, fmin(1, (double)pcm[sample] * c->gain));
            int32_t integer = (int32_t)llround(fmax(-scale, fmin(scale - 1, value * scale)));
            for (unsigned byte = 0; byte < stride; byte++) integerPCM[sample * stride + byte] = (uint8_t)((uint32_t)integer >> (byte * 8));
        }
    }
    uint32_t written = 0, frames = 0;
    if (lhdcv5_enc_encode(c->encoder, integerPCM, c->block * 2 * stride, packet + 14, capacity - 14, &written, &frames)) return false;
    c->consumed += c->block;
    if (!written) return frames == 0;
    if (!frames || frames > 63 || written + 14 > c->mtu || c->emitted + (uint64_t)frames * c->block > c->consumed) return false;
    uint32_t timestamp = (uint32_t)(c->emitted + c->skipped);
    packet[0] = 0x80; packet[1] = 0x60;
    packet[2] = c->sequence >> 8; packet[3] = c->sequence;
    for (unsigned i = 0; i < 4; i++) { packet[4+i] = timestamp >> (24 - i*8); packet[8+i] = c->ssrc >> (24 - i*8); }
    // AOSP layer_specific = (buf_seq << 8) | (written_frames << 2), little endian.
    packet[12] = (uint8_t)(frames << 2); packet[13] = (uint8_t)c->sequence;
    c->emitted += (uint64_t)frames * c->block; c->sequence++;
    *length = written + 14;
    *bitrate = (unsigned)((uint64_t)written * 8 * c->rate / ((uint64_t)frames * c->block) / 1000);
    return true;
}
