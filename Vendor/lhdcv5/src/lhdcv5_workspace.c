/*
 * Encoder workspace and low-level context setup.
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

void lv5e_fdata_all_buffer_new(lv5e_fdata_all_buffer_t *b, int32_t khz_top, int32_t ms_top,
                               int32_t max_frame_size, int32_t max_lossy_umem8_len,
                               int32_t max_freq_repeating) {
  memset(b, 0, sizeof(*b));
  b->khz_top = khz_top;
  b->ms_top = ms_top;
  b->pixel_num_top = max_frame_size;
  b->lossy_symbol_size_top = max_lossy_umem8_len;
  b->freqency_ov_top = max_freq_repeating;
}

int32_t lv5e_fdata_all_buffer_reset(lv5e_fdata_all_buffer_t *b, int32_t ms, int32_t khz,
                                    int32_t resolution, int32_t ch_num,
                                    size_t enc_pixel_size_byte) {
  int32_t khz_calc;
  int32_t fdata_for_ov;
  int32_t result;

  b->ms = ms;
  b->khz = khz;
  b->resolution = resolution;
  b->ch_num = ch_num;
  khz_calc = (khz == 44100) ? 48000 : khz;
  switch (ms) {
    case 25:
      fdata_for_ov = 10;
      break;
    case 50:
      fdata_for_ov = 20;
      break;
    case 75:
    case 100:
      fdata_for_ov = 25;
      break;
    default:
      fdata_for_ov = 0;
      break;
  }

  b->pixel_ov_num = khz_calc * fdata_for_ov / 10000;
  b->pixel_num = khz_calc * ms / 10000;
  b->valid_num = (int32_t)(lv5e_log_2((uint32_t)b->pixel_num) - 1);
  result = lv5e_enc_lossy_frame_length_program((int32_t)enc_pixel_size_byte, b);
  if (result != 0) {
    return result;
  }
  b->fdata_ch_buffer[0].offset_step = 8704.0f / (float)(1 << 9);
  b->fdata_ch_buffer[1].offset_step = b->fdata_ch_buffer[0].offset_step;
  lv5e_freq_top_reset(&b->frequency_mem, b->pixel_num * 2, b->pixel_ov_num,
                      31 - b->resolution);
  b->frame_cnt = 0;
  return 0;
}

/* ---------------- low-level encoder context ---------------- */

int lv5e_enc_context_new(lv5e_enc_context_t *ctx, size_t ch, size_t khz_max,
                         size_t ms_max, uint32_t mode) {
  size_t max_frame_size, max_frame_size_10ms, mult, max_frequency_repeating;
  size_t max_lossy_umem8_len;

  if (ch < 1 || ch > 8 ||
      (khz_max != 8000 && khz_max != 16000 && khz_max != 24000 && khz_max != 32000 &&
       khz_max != 44100 && khz_max != 48000 && khz_max != 96000 && khz_max != 192000) ||
      ms_max != 50 || mode != 0) {
    return -1;
  }
  if (khz_max == 44100) {
    khz_max = 48000;
  }
  /* The static buffers are sized for LHDCV5_MAX_SAMPLE_RATE */
  if (khz_max > LV5E_KHZ_MAX) {
    return -1;
  }
  max_frame_size = khz_max * ms_max / 10000;
  max_frame_size_10ms = max_frame_size * 10;
  mult = 20; /* ms_max == 50 */
  max_frequency_repeating = khz_max * mult / 10000;
  max_lossy_umem8_len = 2 * (max_frame_size_10ms > 960 ? max_frame_size_10ms : 960);

  memset(ctx, 0, sizeof(*ctx));
  ctx->khz_max = khz_max;
  ctx->ms_max = ms_max;
  ctx->max_frame_size = max_frame_size;
  ctx->max_lossy_umem8_len = max_lossy_umem8_len;
  ctx->max_frequency_repeating = max_frequency_repeating;
  lv5e_fdata_all_buffer_new(&ctx->ebuffer, (int32_t)khz_max, (int32_t)ms_max,
                            (int32_t)max_frame_size, (int32_t)max_lossy_umem8_len,
                            (int32_t)max_frequency_repeating);
  return 0;
}

int lv5e_enc_context_set_version(lv5e_enc_context_t *ctx, size_t version) {
  if (version > 3) {
    return -1;
  }
  lv5e_header_set_info(&ctx->hdr_s, LV5E_VERSION_INDEX, (int32_t)version);
  return 0;
}
