/*
 * LHDC V5 (lossy) Bluetooth audio encoder, portable C99.
 *
 * Copyright (C) 2025, The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Portability notes:
 *  - C99, no OS dependencies, no dynamic allocation required
 *    (see lhdcv5_enc_context_size / lhdcv5_enc_setup_mem).
 *  - Assumes a little-endian target with 32-bit int (ESP32, ARM Cortex-M/A,
 *    RISC-V, x86...). Compile-time checked in the sources.
 *  - RAM usage is dominated by the encoder context. To shrink it on small
 *    targets, define LHDCV5_MAX_SAMPLE_RATE to 48000 or 96000 at compile
 *    time (default 192000). Sample rates above the cap are then rejected
 *    at init time.
 *      LHDCV5_MAX_SAMPLE_RATE=192000  -> context ~= 117 KB
 *      LHDCV5_MAX_SAMPLE_RATE=96000   -> context ~=  73 KB
 *      LHDCV5_MAX_SAMPLE_RATE=48000   -> context ~=  51 KB
 */
#ifndef LHDCV5_ENC_H
#define LHDCV5_ENC_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* Constants (standard LHDC V5 API values)                             */
/* ------------------------------------------------------------------ */

/* Function return codes (STATUS_LHDC_BT) */
#define LHDC_FRET_SUCCESS 0
#define LHDC_FRET_INVALID_INPUT_PARAM (-1)
#define LHDC_FRET_INVALID_HANDLE_CB (-2)
#define LHDC_FRET_INVALID_HANDLE_PARA (-3)
#define LHDC_FRET_INVALID_HANDLE_ENC (-4)
#define LHDC_FRET_INVALID_HANDLE_CBUF (-5)
#define LHDC_FRET_INVALID_HANDLE_AR (-6)
#define LHDC_FRET_INVALID_CODEC (-7)
#define LHDC_FRET_CODEC_NOT_READY (-8)
#define LHDC_FRET_AR_NOT_READY (-9)
#define LHDC_FRET_ERROR (-10)
#define LHDC_FRET_BUF_NOT_ENOUGH (-11)

/* Sample rates */
#define LHDC_SR_44100HZ 44100u
#define LHDC_SR_48000HZ 48000u
#define LHDC_SR_96000HZ 96000u
#define LHDC_SR_192000HZ 192000u

/* Bits per sample (input PCM format: packed s16le or packed s24le, 3 bytes) */
#define LHDCBT_SMPL_FMT_S16 16u
#define LHDCBT_SMPL_FMT_S24 24u

/* Frame duration (only 5 ms is supported by LHDC V5) */
#define LHDC_FRAME_5MS 50u

/* Encode interval */
#define LHDC_ENC_INTERVAL_10MS 10u
#define LHDC_ENC_INTERVAL_20MS 20u

/* Quality / bitrate index */
#define LHDC_QUALITY_LOW0 0u   /*   64 kbps */
#define LHDC_QUALITY_LOW1 1u   /*  160 kbps */
#define LHDC_QUALITY_LOW2 2u   /*  192 kbps */
#define LHDC_QUALITY_LOW3 3u   /*  240/256 kbps */
#define LHDC_QUALITY_LOW4 4u   /*  320 kbps */
#define LHDC_QUALITY_LOW 5u    /*  400 kbps */
#define LHDC_QUALITY_MID 6u    /*  480/500 kbps */
#define LHDC_QUALITY_HIGH 7u   /*  900 kbps */
#define LHDC_QUALITY_HIGH1 8u  /* 1000 kbps */
#define LHDC_QUALITY_HIGH2 9u  /* 1100 kbps */
#define LHDC_QUALITY_HIGH3 10u /* 1200 kbps */
#define LHDC_QUALITY_HIGH4 11u /* 1300 kbps */
#define LHDC_QUALITY_HIGH5 12u /* 1400 kbps */
#define LHDC_QUALITY_MAX_BITRATE 12u
#define LHDC_QUALITY_AUTO 13u
#define LHDC_QUALITY_UNLIMIT 14u
#define LHDC_QUALITY_INVALID 130u

/* MTU sizes */
#define LHDC_MTU_MIN 300u
#define LHDC_MTU_2MBPS 660u
#define LHDC_MTU_3MBPS 1023u
#define LHDC_MTU_MHDT_4DH5 1392u
#define LHDC_MTU_MHDT_6DH5 2089u
#define LHDC_MTU_MHDT_8DH5 2820u
#define LHDC_MTU_MAX 8192u

/* Codec version passed to lhdcv5_enc_new / lhdcv5_enc_setup_mem */
#define LHDC_VERSION_1 1u

/* ------------------------------------------------------------------ */
/* Handle                                                              */
/* ------------------------------------------------------------------ */

typedef struct lhdcv5_enc lhdcv5_enc_t; /* opaque */

/* Size in bytes needed for one encoder context (for static allocation). */
size_t lhdcv5_enc_context_size(void);

/*
 * Initialize an encoder context in caller-provided memory.
 * `mem` must be at least lhdcv5_enc_context_size() bytes and 8-byte aligned
 * (e.g. a static uint64_t array). `version` must be LHDC_VERSION_1.
 * Returns the handle, or NULL on bad parameters.
 */
lhdcv5_enc_t *lhdcv5_enc_setup_mem(void *mem, uint32_t version);

#ifndef LHDCV5_NO_MALLOC
/* Heap convenience wrappers (uses malloc/free). */
lhdcv5_enc_t *lhdcv5_enc_new(uint32_t version);
void lhdcv5_enc_free(lhdcv5_enc_t *h);
#endif

/* ------------------------------------------------------------------ */
/* Encoder API                                                         */
/* ------------------------------------------------------------------ */

/*
 * Configure the encoder.
 *   sampling_freq   44100 / 48000 / 96000 / 192000
 *   bits_per_sample 16 (packed s16le) or 24 (packed s24le, 3 bytes/sample)
 *   bitrate_inx     LHDC_QUALITY_* index (or LHDC_QUALITY_AUTO)
 *   mtu             link MTU in bytes, LHDC_MTU_MIN..LHDC_MTU_MAX
 *   interval        LHDC_ENC_INTERVAL_10MS or _20MS
 * Input is always 2-channel interleaved PCM.
 */
int32_t lhdcv5_enc_init_encoder(lhdcv5_enc_t *h, uint32_t sampling_freq,
                                uint32_t bits_per_sample, uint32_t bitrate_inx,
                                uint32_t mtu, uint32_t interval);

/* Samples per frame per channel (240 / 480 / 960 depending on rate). */
int32_t lhdcv5_enc_get_block_size(const lhdcv5_enc_t *h, uint32_t *samples_per_frame);

/*
 * Encode exactly one frame of interleaved stereo PCM.
 *   in_pcm      block_size * 2 interleaved samples
 *               (block_size*2*2 bytes for S16, block_size*2*3 bytes for S24)
 *   out_buf     receives 0 or more complete LHDC frames. Frames are held in
 *               an internal queue until a full packet's worth is available,
 *               so *written_bytes is 0 for most calls and a packet
 *               (up to ~MTU bytes) every N-th call.
 * Returns LHDC_FRET_SUCCESS or a negative error.
 */
int32_t lhdcv5_enc_encode(lhdcv5_enc_t *h, const uint8_t *in_pcm, size_t in_pcm_len,
                          uint8_t *out_buf, size_t out_buf_len,
                          uint32_t *written_bytes, uint32_t *written_frames);

/* Bitrate control */
int32_t lhdcv5_enc_set_bitrate_index(lhdcv5_enc_t *h, uint32_t bitrate_inx,
                                     bool update_quality_status);
int32_t lhdcv5_enc_set_max_bitrate_index(lhdcv5_enc_t *h, uint32_t max_bitrate_inx);
int32_t lhdcv5_enc_set_min_bitrate_index(lhdcv5_enc_t *h, uint32_t min_bitrate_inx);
int32_t lhdcv5_enc_get_bitrate_index(const lhdcv5_enc_t *h, uint32_t bitrate_kbps,
                                     uint32_t *bitrate_inx);
int32_t lhdcv5_enc_get_last_bitrate(const lhdcv5_enc_t *h, uint32_t *bitrate_kbps);
int32_t lhdcv5_enc_get_quality_mode(const lhdcv5_enc_t *h, uint32_t *quality_status);

#ifdef __cplusplus
}
#endif

#endif /* LHDCV5_ENC_H */
