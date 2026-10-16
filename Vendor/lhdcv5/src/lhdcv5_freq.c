/*
 * MDCT-style frequency transform: windowing, pre/post twiddles, FFT.
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

#include <math.h>

#define FP_PI 3.14159265358979323846264338327950288

static int32_t calc_pos_twid_scale_int_bits(int32_t n4) {
  int32_t i = 0;
  int32_t keep_positive_bits = 0;
  if (n4 <= 0) {
    return 0;
  }
  while ((1 << i) <= (1 << 15) / n4) {
    keep_positive_bits += 1;
    i += 1;
  }
  return 31 - keep_positive_bits;
}

static int32_t sat_i32(int64_t v) {
  if (v > 2147483647LL) {
    return 2147483647;
  }
  if (v < -2147483647LL - 1) {
    return -2147483647 - 1;
  }
  return (int32_t)v;
}

static void lv5e_enc_lossy_frequency_overlap(int32_t repeating, int32_t *win_hann) {
  int32_t i;
  for (i = 0; i < repeating; i++) {
    double sin_tmp = sin(0.5 * FP_PI * ((double)i + 0.5) / (double)repeating);
    float win_data = (float)sin(0.5 * FP_PI * sin_tmp * sin_tmp);
    int64_t win_tmp = (int64_t)(win_data * (float)(1LL << 31));
    win_hann[i] = sat_i32(win_tmp);
  }
}

static void freq_top_resolve(lv5e_freq_top_t *t) {
  int32_t num1 = t->num1;
  int32_t num2 = t->num2;
  int32_t sft_num = t->offset_num;
  float scale;
  int64_t pos_twid_scalar_shift_val;
  int32_t i;

  t->pos_twid_scalar_shift = calc_pos_twid_scale_int_bits(num2);
  scale = (float)(1 << sft_num) / (float)num2;
  pos_twid_scalar_shift_val = 1LL << t->pos_twid_scalar_shift;

  for (i = 0; i < num2; i++) {
    float x = (float)(-FP_PI * ((double)i + 0.25) / (double)num1);
    int64_t r_tmp = (int64_t)((float)cos((double)x) * (float)(1LL << 31));
    int64_t i_tmp = (int64_t)((float)sin((double)x) * (float)(1LL << 31));
    t->pre_twid[i].r = sat_i32(r_tmp);
    t->pre_twid[i].i = sat_i32(i_tmp);

    x = (float)(-FP_PI * (double)i / (double)num1);
    r_tmp = (int64_t)((float)(cos((double)x) * (double)scale) *
                      (float)pos_twid_scalar_shift_val);
    i_tmp = (int64_t)((float)(sin((double)x) * (double)scale) *
                      (float)pos_twid_scalar_shift_val);
    t->pos_twid[i].r = sat_i32(r_tmp);
    t->pos_twid[i].i = sat_i32(i_tmp);
  }
  lv5e_enc_lossy_frequency_overlap(t->repeating, t->freqency_win);
  t->pos_twid_scalar_shift = calc_pos_twid_scale_int_bits(t->num2);
  lv5e_fft_reset(&t->kiss_fft_cfg, t->num2, 0);
}

void lv5e_freq_top_reset(lv5e_freq_top_t *t, int32_t frequency_size, int32_t repeating,
                         int32_t sft_num) {
  t->repeating = repeating;
  t->size = frequency_size;
  t->num1 = frequency_size / 2;
  t->num2 = t->num1 / 2;
  t->num3 = repeating / 2;
  t->num4 = (frequency_size - t->num1 - repeating) / 2;
  t->offset_num = sft_num;
  freq_top_resolve(t);
}

void lv5e_enc_lossy_frequency_operation(lv5e_freq_top_t *frequency, int32_t c,
                                        int32_t *output) {
  /* fft_coef_in doubles as a flat i32 scratch buffer; the aliasing is
   * intentional and load-bearing */
  int32_t *input = (int32_t *)frequency->frequency_buffers.fft_coef_in;
  lv5e_complex_t *fft_coef_out = frequency->frequency_buffers.fft_coef_out;
  int32_t *fft_iv = frequency->frequency_buffers.fft_iv;
  int32_t scalar_shift = frequency->offset_num;
  int32_t pos_twid_scalar_shift = frequency->pos_twid_scalar_shift;
  size_t num1 = (size_t)frequency->num1;
  size_t num2 = (size_t)frequency->num2;
  size_t num3 = (size_t)frequency->num3;
  size_t num4 = (size_t)frequency->num4;
  size_t repeating = (size_t)frequency->repeating;
  int32_t *freq_repeat = frequency->frequency_process_ch_num.repeat_size_top +
                         frequency->frequency_process_ch_num.offset;
  lv5e_complex_t *fft_coef_in;
  size_t i;
  (void)c;

  for (i = 0; i < num1; i++) {
    input[i] <<= scalar_shift;
  }
  for (i = 0; i < num4; i++) {
    fft_iv[num3 + i] = -input[num1 - repeating - 1 - i];
    fft_iv[num2 + i] = -input[num4 - 1 - i];
  }
  for (i = 0; i < num3; i++) {
    int64_t fresh20 = input[num1 - num3 - 1 - i];
    int64_t fresh21 = frequency->freqency_win[num3 + i];
    int64_t fresh22 = input[num1 - num3 + i];
    int64_t fresh23 = frequency->freqency_win[num3 - 1 - i];
    int64_t fresh40, fresh41, fresh42, fresh43;
    fft_iv[i] = (int32_t)((-fresh20 * fresh21 - fresh22 * fresh23) >> 31);
    fresh40 = freq_repeat[i];
    fresh41 = frequency->freqency_win[i];
    fresh42 = freq_repeat[repeating - 1 - i];
    fresh43 = frequency->freqency_win[repeating - 1 - i];
    fft_iv[num2 + num4 + i] = (int32_t)((fresh40 * fresh41 - fresh42 * fresh43) >> 31);
  }
  for (i = 0; i < repeating; i++) {
    freq_repeat[i] = input[num1 - repeating + i];
  }

  fft_coef_in = frequency->frequency_buffers.fft_coef_in;

  for (i = 0; i < num2; i++) {
    int64_t pdr_tmp_0 = fft_iv[i * 2];
    int64_t pdi_tmp_0 = fft_iv[num1 - 1 - i * 2];
    int64_t freq_pre_twid_r_tmp_0 = frequency->pre_twid[i].r;
    int64_t freq_pre_twid_i_tmp_0 = frequency->pre_twid[i].i;
    fft_coef_in[i].r = (int32_t)((pdr_tmp_0 * freq_pre_twid_r_tmp_0 -
                                  pdi_tmp_0 * freq_pre_twid_i_tmp_0) >>
                                 31);
    fft_coef_in[i].i = (int32_t)((pdi_tmp_0 * freq_pre_twid_r_tmp_0 +
                                  pdr_tmp_0 * freq_pre_twid_i_tmp_0) >>
                                 31);
  }

  lv5e_fft(&frequency->kiss_fft_cfg, fft_coef_in, fft_coef_out);

  for (i = 0; i < num2; i++) {
    int64_t cout_r = fft_coef_out[i].r;
    int64_t cout_i = fft_coef_out[i].i;
    int64_t freq_pos_r = frequency->pos_twid[i].r;
    int64_t freq_pos_i = frequency->pos_twid[i].i;
    output[2 * i] = (int32_t)((((cout_r * freq_pos_r - cout_i * freq_pos_i) >>
                                scalar_shift) *
                               (int64_t)num2) >>
                              pos_twid_scalar_shift);
    output[num1 - 1 - 2 * i] =
        (int32_t)((((-(cout_i * freq_pos_r + cout_r * freq_pos_i)) >> scalar_shift) *
                   (int64_t)num2) >>
                  pos_twid_scalar_shift);
  }
}
