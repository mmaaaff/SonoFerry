/*
 * Fixed-point FFT, based on KISS FFT.
 *
 * Copyright (c) 2003-2010, Mark Borgerding. All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 */
#include "lhdcv5_int.h"

#include <math.h>

#define KISS_PI 3.14159265358979323846264338327950288

/* ((a*b + 2^30) >> 31) fixed-point multiply used throughout */
static inline int32_t smul(int32_t a, int32_t b) {
  return (int32_t)(((int64_t)a * (int64_t)b + (1LL << 30)) >> 31);
}

static void kf_factor(int32_t n, int32_t *facbuf) {
  int32_t p = 4;
  int32_t floor_sqrt = (int32_t)(lv5e_sqrtf((float)n) + 0.5f);
  size_t i = 0;
  do {
    while (n % p != 0) {
      switch (p) {
        case 4:
          p = 2;
          break;
        case 2:
          p = 3;
          break;
        default:
          p += 2;
          break;
      }
      if (p > floor_sqrt) {
        p = n;
      }
    }
    n /= p;
    facbuf[i++] = p;
    facbuf[i++] = n;
  } while (n > 1);
}

void lv5e_fft_reset(lv5e_fft_state_t *st, int32_t nfft, int32_t inverse) {
  int32_t i;
  st->nfft = nfft;
  st->inverse = inverse;
  for (i = 0; i < nfft; i++) {
    double phase = -2.0 * KISS_PI * (double)i / (double)nfft;
    if (inverse != 0) {
      phase *= -1.0;
    }
    st->twiddles[i].r = (int32_t)floor(0.5 + 2147483647.0 * cos(phase));
    st->twiddles[i].i = (int32_t)floor(0.5 + 2147483647.0 * sin(phase));
  }
  kf_factor(nfft, st->factors);
}

static void kf_bfly2(lv5e_complex_t *f_out, size_t fstride, lv5e_fft_state_t *st,
                     int32_t m) {
  const lv5e_complex_t *tw1 = st->twiddles;
  lv5e_complex_t *f_out_2 = f_out + m;
  lv5e_complex_t t;
  do {
    lv5e_complex_t tw = tw1[0];
    f_out[0].r >>= 1;
    f_out[0].i >>= 1;
    f_out_2[0].r >>= 1;
    f_out_2[0].i >>= 1;
    t.r = (int32_t)(((int64_t)f_out_2[0].r * tw.r - (int64_t)f_out_2[0].i * tw.i +
                     (1LL << 30)) >>
                    31);
    t.i = (int32_t)(((int64_t)f_out_2[0].r * tw.i + (int64_t)f_out_2[0].i * tw.r +
                     (1LL << 30)) >>
                    31);
    tw1 += fstride;
    f_out_2[0].r = f_out[0].r - t.r;
    f_out_2[0].i = f_out[0].i - t.i;
    f_out[0].r += t.r;
    f_out[0].i += t.i;
    f_out_2 += 1;
    f_out += 1;
    m -= 1;
  } while (m != 0);
}

static void kf_bfly4(lv5e_complex_t *f_out, size_t fstride, lv5e_fft_state_t *st,
                     size_t m) {
  lv5e_complex_t scratch[6];
  size_t k = m;
  size_t m2 = 2 * m;
  size_t m3 = 3 * m;
  const lv5e_complex_t *tw = st->twiddles;
  size_t twi1 = 0, twi2 = 0, twi3 = 0;
  do {
    f_out[0].r >>= 2;
    f_out[0].i >>= 2;
    f_out[m].r >>= 2;
    f_out[m].i >>= 2;
    f_out[m2].r >>= 2;
    f_out[m2].i >>= 2;
    f_out[m3].r >>= 2;
    f_out[m3].i >>= 2;
    scratch[0].r = (int32_t)(((int64_t)f_out[m].r * tw[twi1].r -
                              (int64_t)f_out[m].i * tw[twi1].i + (1LL << 30)) >>
                             31);
    scratch[0].i = (int32_t)(((int64_t)f_out[m].r * tw[twi1].i +
                              (int64_t)f_out[m].i * tw[twi1].r + (1LL << 30)) >>
                             31);
    scratch[1].r = (int32_t)(((int64_t)f_out[m2].r * tw[twi2].r -
                              (int64_t)f_out[m2].i * tw[twi2].i + (1LL << 30)) >>
                             31);
    scratch[1].i = (int32_t)(((int64_t)f_out[m2].r * tw[twi2].i +
                              (int64_t)f_out[m2].i * tw[twi2].r + (1LL << 30)) >>
                             31);
    scratch[2].r = (int32_t)(((int64_t)f_out[m3].r * tw[twi3].r -
                              (int64_t)f_out[m3].i * tw[twi3].i + (1LL << 30)) >>
                             31);
    scratch[2].i = (int32_t)(((int64_t)f_out[m3].r * tw[twi3].i +
                              (int64_t)f_out[m3].i * tw[twi3].r + (1LL << 30)) >>
                             31);
    scratch[5].r = f_out[0].r - scratch[1].r;
    scratch[5].i = f_out[0].i - scratch[1].i;
    f_out[0].r += scratch[1].r;
    f_out[0].i += scratch[1].i;
    scratch[3].r = scratch[0].r + scratch[2].r;
    scratch[3].i = scratch[0].i + scratch[2].i;
    scratch[4].r = scratch[0].r - scratch[2].r;
    scratch[4].i = scratch[0].i - scratch[2].i;
    f_out[m2].r = f_out[0].r - scratch[3].r;
    f_out[m2].i = f_out[0].i - scratch[3].i;
    twi1 += fstride;
    twi2 += fstride * 2;
    twi3 += fstride * 3;
    f_out[0].r += scratch[3].r;
    f_out[0].i += scratch[3].i;
    if (st->inverse != 0) {
      f_out[m].r = scratch[5].r - scratch[4].i;
      f_out[m].i = scratch[5].i + scratch[4].r;
      f_out[m3].r = scratch[5].r + scratch[4].i;
      f_out[m3].i = scratch[5].i - scratch[4].r;
    } else {
      f_out[m].r = scratch[5].r + scratch[4].i;
      f_out[m].i = scratch[5].i - scratch[4].r;
      f_out[m3].r = scratch[5].r - scratch[4].i;
      f_out[m3].i = scratch[5].i + scratch[4].r;
    }
    f_out += 1;
    k -= 1;
  } while (k != 0);
}

static void kf_bfly3(lv5e_complex_t *f_out, size_t fstride, lv5e_fft_state_t *st,
                     size_t m) {
  size_t k = m;
  size_t m2 = 2 * m;
  lv5e_complex_t scratch[5];
  const lv5e_complex_t *tw = st->twiddles;
  lv5e_complex_t epi3 = tw[fstride * m];
  size_t twi1 = 0, twi2 = 0;
  do {
    f_out[0].r = smul(f_out[0].r, 2147483647 / 3);
    f_out[0].i = smul(f_out[0].i, 2147483647 / 3);
    f_out[m].r = smul(f_out[m].r, 2147483647 / 3);
    f_out[m].i = smul(f_out[m].i, 2147483647 / 3);
    f_out[m2].r = smul(f_out[m2].r, 2147483647 / 3);
    f_out[m2].i = smul(f_out[m2].i, 2147483647 / 3);
    scratch[1].r = (int32_t)(((int64_t)f_out[m].r * tw[twi1].r -
                              (int64_t)f_out[m].i * tw[twi1].i + (1LL << 30)) >>
                             31);
    scratch[1].i = (int32_t)(((int64_t)f_out[m].r * tw[twi1].i +
                              (int64_t)f_out[m].i * tw[twi1].r + (1LL << 30)) >>
                             31);
    scratch[2].r = (int32_t)(((int64_t)f_out[m2].r * tw[twi2].r -
                              (int64_t)f_out[m2].i * tw[twi2].i + (1LL << 30)) >>
                             31);
    scratch[2].i = (int32_t)(((int64_t)f_out[m2].r * tw[twi2].i +
                              (int64_t)f_out[m2].i * tw[twi2].r + (1LL << 30)) >>
                             31);
    scratch[3].r = scratch[1].r + scratch[2].r;
    scratch[3].i = scratch[1].i + scratch[2].i;
    scratch[0].r = scratch[1].r - scratch[2].r;
    scratch[0].i = scratch[1].i - scratch[2].i;
    twi1 += fstride;
    twi2 += fstride * 2;
    f_out[m].r = f_out[0].r - (scratch[3].r >> 1);
    f_out[m].i = f_out[0].i - (scratch[3].i >> 1);
    scratch[0].r = smul(scratch[0].r, epi3.i);
    scratch[0].i = smul(scratch[0].i, epi3.i);
    f_out[0].r += scratch[3].r;
    f_out[0].i += scratch[3].i;
    f_out[m2].r = f_out[m].r + scratch[0].i;
    f_out[m2].i = f_out[m].i - scratch[0].r;
    f_out[m].r -= scratch[0].i;
    f_out[m].i += scratch[0].r;
    f_out += 1;
    k -= 1;
  } while (k != 0);
}

static void kf_bfly5(lv5e_complex_t *f_out, size_t fstride, lv5e_fft_state_t *st,
                     size_t m) {
  lv5e_complex_t scratch[13];
  const lv5e_complex_t *twiddles = st->twiddles;
  lv5e_complex_t ya = twiddles[fstride * m];
  lv5e_complex_t yb = twiddles[2 * fstride * m];
  lv5e_complex_t *f_out_0 = f_out;
  lv5e_complex_t *f_out_1 = f_out + m;
  lv5e_complex_t *f_out_2 = f_out + 2 * m;
  lv5e_complex_t *f_out_3 = f_out + 3 * m;
  lv5e_complex_t *f_out_4 = f_out + 4 * m;
  size_t u;
  for (u = 0; u < m; u++) {
    f_out_0[0].r = smul(f_out_0[0].r, 2147483647 / 5);
    f_out_0[0].i = smul(f_out_0[0].i, 2147483647 / 5);
    f_out_1[0].r = smul(f_out_1[0].r, 2147483647 / 5);
    f_out_1[0].i = smul(f_out_1[0].i, 2147483647 / 5);
    f_out_2[0].r = smul(f_out_2[0].r, 2147483647 / 5);
    f_out_2[0].i = smul(f_out_2[0].i, 2147483647 / 5);
    f_out_3[0].r = smul(f_out_3[0].r, 2147483647 / 5);
    f_out_3[0].i = smul(f_out_3[0].i, 2147483647 / 5);
    f_out_4[0].r = smul(f_out_4[0].r, 2147483647 / 5);
    f_out_4[0].i = smul(f_out_4[0].i, 2147483647 / 5);
    scratch[0] = f_out_0[0];
    scratch[1].r = (int32_t)(((int64_t)f_out_1[0].r * twiddles[u * fstride].r -
                              (int64_t)f_out_1[0].i * twiddles[u * fstride].i +
                              (1LL << 30)) >>
                             31);
    scratch[1].i = (int32_t)(((int64_t)f_out_1[0].r * twiddles[u * fstride].i +
                              (int64_t)f_out_1[0].i * twiddles[u * fstride].r +
                              (1LL << 30)) >>
                             31);
    scratch[2].r = (int32_t)(((int64_t)f_out_2[0].r * twiddles[2 * u * fstride].r -
                              (int64_t)f_out_2[0].i * twiddles[2 * u * fstride].i +
                              (1LL << 30)) >>
                             31);
    scratch[2].i = (int32_t)(((int64_t)f_out_2[0].r * twiddles[2 * u * fstride].i +
                              (int64_t)f_out_2[0].i * twiddles[2 * u * fstride].r +
                              (1LL << 30)) >>
                             31);
    scratch[3].r = (int32_t)(((int64_t)f_out_3[0].r * twiddles[3 * u * fstride].r -
                              (int64_t)f_out_3[0].i * twiddles[3 * u * fstride].i +
                              (1LL << 30)) >>
                             31);
    scratch[3].i = (int32_t)(((int64_t)f_out_3[0].r * twiddles[3 * u * fstride].i +
                              (int64_t)f_out_3[0].i * twiddles[3 * u * fstride].r +
                              (1LL << 30)) >>
                             31);
    scratch[4].r = (int32_t)(((int64_t)f_out_4[0].r * twiddles[4 * u * fstride].r -
                              (int64_t)f_out_4[0].i * twiddles[4 * u * fstride].i +
                              (1LL << 30)) >>
                             31);
    scratch[4].i = (int32_t)(((int64_t)f_out_4[0].r * twiddles[4 * u * fstride].i +
                              (int64_t)f_out_4[0].i * twiddles[4 * u * fstride].r +
                              (1LL << 30)) >>
                             31);
    scratch[7].r = scratch[1].r + scratch[4].r;
    scratch[7].i = scratch[1].i + scratch[4].i;
    scratch[10].r = scratch[1].r - scratch[4].r;
    scratch[10].i = scratch[1].i - scratch[4].i;
    scratch[8].r = scratch[2].r + scratch[3].r;
    scratch[8].i = scratch[2].i + scratch[3].i;
    scratch[9].r = scratch[2].r - scratch[3].r;
    scratch[9].i = scratch[2].i - scratch[3].i;
    f_out_0[0].r += scratch[7].r + scratch[8].r;
    f_out_0[0].i += scratch[7].i + scratch[8].i;
    scratch[5].r = scratch[0].r + smul(scratch[7].r, ya.r) + smul(scratch[8].r, yb.r);
    scratch[5].i = scratch[0].i + smul(scratch[7].i, ya.r) + smul(scratch[8].i, yb.r);
    scratch[6].r = smul(scratch[10].i, ya.i) + smul(scratch[9].i, yb.i);
    scratch[6].i = -smul(scratch[10].r, ya.i) - smul(scratch[9].r, yb.i);
    f_out_1[0].r = scratch[5].r - scratch[6].r;
    f_out_1[0].i = scratch[5].i - scratch[6].i;
    f_out_4[0].r = scratch[5].r + scratch[6].r;
    f_out_4[0].i = scratch[5].i + scratch[6].i;
    scratch[11].r = scratch[0].r + smul(scratch[7].r, yb.r) + smul(scratch[8].r, ya.r);
    scratch[11].i = scratch[0].i + smul(scratch[7].i, yb.r) + smul(scratch[8].i, ya.r);
    scratch[12].r = -smul(scratch[10].i, yb.i) + smul(scratch[9].i, ya.i);
    scratch[12].i = smul(scratch[10].r, yb.i) - smul(scratch[9].r, ya.i);
    f_out_2[0].r = scratch[11].r + scratch[12].r;
    f_out_2[0].i = scratch[11].i + scratch[12].i;
    f_out_3[0].r = scratch[11].r - scratch[12].r;
    f_out_3[0].i = scratch[11].i - scratch[12].i;
    f_out_0 += 1;
    f_out_1 += 1;
    f_out_2 += 1;
    f_out_3 += 1;
    f_out_4 += 1;
  }
}

static const uint8_t FREQUENCY_OFFSET_120[24] = {0, 8,  16, 4, 12, 20, 1, 9,
                                                 17, 5, 13, 21, 2, 10, 18, 6,
                                                 14, 22, 3, 11, 19, 7, 15, 23};

static const uint8_t FREQUENCY_OFFSET_240[48] = {
    0, 16, 32, 4, 20, 36, 8, 24, 40, 12, 28, 44, 1, 17, 33, 5, 21, 37, 9, 25, 41, 13, 29,
    45, 2, 18, 34, 6, 22, 38, 10, 26, 42, 14, 30, 46, 3, 19, 35, 7, 23, 39, 11, 27, 43,
    15, 31, 47};

static const uint8_t FREQUENCY_OFFSET_480[96] = {
    0, 32, 64, 16, 48, 80, 4, 36, 68, 20, 52, 84, 8, 40, 72, 24, 56, 88, 12, 44, 76, 28,
    60, 92, 1, 33, 65, 17, 49, 81, 5, 37, 69, 21, 53, 85, 9, 41, 73, 25, 57, 89, 13, 45,
    77, 29, 61, 93, 2, 34, 66, 18, 50, 82, 6, 38, 70, 22, 54, 86, 10, 42, 74, 26, 58, 90,
    14, 46, 78, 30, 62, 94, 3, 35, 67, 19, 51, 83, 7, 39, 71, 23, 55, 87, 11, 43, 75, 27,
    59, 91, 15, 47, 79, 31, 63, 95};

static void kf_work_120(lv5e_complex_t *f_out, const lv5e_complex_t *f,
                        lv5e_fft_state_t *st) {
  int32_t counter_0 = 0, counter_1 = 0, counter_2 = 0;
  size_t i;
  for (i = 0; i < 24; i++) {
    const lv5e_complex_t *f_tmp = f + FREQUENCY_OFFSET_120[i];
    f_out[i * 5] = f_tmp[0];
    f_out[i * 5 + 1] = f_tmp[24];
    f_out[i * 5 + 2] = f_tmp[48];
    f_out[i * 5 + 3] = f_tmp[72];
    f_out[i * 5 + 4] = f_tmp[96];
    kf_bfly5(f_out + i * 5, 24, st, 1);
    counter_0 += 1;
    if (counter_0 == 3) {
      kf_bfly3(f_out + (i - 2) * 5, 8, st, 5);
      counter_1 += 1;
      counter_0 = 0;
    }
    if (counter_1 == 2) {
      kf_bfly2(f_out + (i - 5) * 5, 4, st, 15);
      counter_2 += 1;
      counter_1 = 0;
    }
    if (counter_2 == 4) {
      kf_bfly4(f_out + (i - 23) * 5, 1, st, 30);
    }
  }
}

static void kf_work_240(lv5e_complex_t *f_out, const lv5e_complex_t *f,
                        lv5e_fft_state_t *st) {
  int32_t counter_0 = 0, counter_1 = 0, counter_2 = 0;
  size_t i;
  for (i = 0; i < 48; i++) {
    const lv5e_complex_t *f_tmp = f + FREQUENCY_OFFSET_240[i];
    f_out[i * 5] = f_tmp[0];
    f_out[i * 5 + 1] = f_tmp[48];
    f_out[i * 5 + 2] = f_tmp[96];
    f_out[i * 5 + 3] = f_tmp[144];
    f_out[i * 5 + 4] = f_tmp[192];
    kf_bfly5(f_out + i * 5, 48, st, 1);
    counter_0 += 1;
    if (counter_0 == 3) {
      kf_bfly3(f_out + (i + 1) * 5 - 15, 16, st, 5);
      counter_1 += 1;
      counter_0 = 0;
    }
    if (counter_1 == 4) {
      kf_bfly4(f_out + (i + 1) * 5 - 60, 4, st, 15);
      counter_2 += 1;
      counter_1 = 0;
    }
    if (counter_2 == 4) {
      kf_bfly4(f_out + (i + 1) * 5 - 240, 1, st, 60);
    }
  }
}

static void kf_work_480(lv5e_complex_t *f_out, const lv5e_complex_t *f,
                        lv5e_fft_state_t *st) {
  int32_t counter_0 = 0, counter_1 = 0, counter_2 = 0, counter_3 = 0;
  size_t i;
  for (i = 0; i < 96; i++) {
    const lv5e_complex_t *f_tmp = f + FREQUENCY_OFFSET_480[i];
    f_out[i * 5] = f_tmp[0];
    f_out[i * 5 + 1] = f_tmp[96];
    f_out[i * 5 + 2] = f_tmp[192];
    f_out[i * 5 + 3] = f_tmp[288];
    f_out[i * 5 + 4] = f_tmp[384];
    kf_bfly5(f_out + (i + 1) * 5 - 5, 96, st, 1);
    counter_0 += 1;
    if (counter_0 == 3) {
      kf_bfly3(f_out + (i + 1) * 5 - 15, 32, st, 5);
      counter_1 += 1;
      counter_0 = 0;
    }
    if (counter_1 == 2) {
      kf_bfly2(f_out + (i + 1) * 5 - 30, 16, st, 15);
      counter_2 += 1;
      counter_1 = 0;
    }
    if (counter_2 == 4) {
      kf_bfly4(f_out + (i + 1) * 5 - 120, 4, st, 30);
      counter_3 += 1;
      counter_2 = 0;
    }
    if (counter_3 == 4) {
      kf_bfly4(f_out + (i + 1) * 5 - 480, 1, st, 120);
    }
  }
}

void lv5e_fft(lv5e_fft_state_t *cfg, const lv5e_complex_t *f_in, lv5e_complex_t *f_out) {
  switch (cfg->nfft) {
    case 120:
      kf_work_120(f_out, f_in, cfg);
      break;
    case 240:
      kf_work_240(f_out, f_in, cfg);
      break;
    case 480:
      kf_work_480(f_out, f_in, cfg);
      break;
    default:
      break;
  }
}
