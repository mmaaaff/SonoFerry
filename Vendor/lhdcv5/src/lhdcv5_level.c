/*
 * Quantization level table (lazily cached 1/2^x levels).
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

#define OFFSET_MAX ((1 << 9) - 8)

static float gmax_calc(float a, float b, float c, int32_t d, int32_t len, int32_t e) {
  return a - (b - c) / (float)d * (float)(len - e);
}

/*
 * Computes a function of `offset_idx` with:
 * - Slope 1 from 0 to `start`
 * - Slope `jump` from `start` to OFFSET_MAX
 * - Slope 1 thereafter
 * - A maximum of 30.0
 */
static float level_calc(const lv5e_level_table_t *t, int32_t offset_idx) {
  int32_t lo = offset_idx < OFFSET_MAX ? offset_idx : OFFSET_MAX;
  int32_t hi = offset_idx > OFFSET_MAX ? offset_idx : OFFSET_MAX;
  float offset = (float)(lo - t->start) * t->jump + (float)t->start;
  offset += (float)(hi - OFFSET_MAX);
  return offset < 30.0f ? offset : 30.0f;
}

float lv5e_level_table_level(lv5e_level_table_t *t, int32_t offset_idx) {
  if (t->cache[offset_idx] != 0.0f) {
    return t->cache[offset_idx];
  }
  if (offset_idx > t->start) {
    t->cache[offset_idx] = 1.0f / lv5e_power_of_2(level_calc(t, offset_idx));
  } else {
    t->cache[offset_idx] = 1.0f / (float)(1 << offset_idx);
  }
  return t->cache[offset_idx];
}

void lv5e_level_table_init(lv5e_level_table_t *t, int32_t size, int32_t resolution,
                           int32_t hz, int32_t ms) {
  float offset_max = 30.0f;
  int32_t deno;

  t->start = 1;
  memset(t->cache, 0, sizeof(t->cache));

  if (ms % 25 == 0 && ms <= 100) {
    switch (resolution) {
      case 24:
        switch (hz) {
          case 8000:
          case 16000:
          case 24000:
          case 32000:
          case 44100:
          case 48000:
            offset_max = gmax_calc(26.2f, 26.2f, 16.4f, 575, size, 50);
            break;
          case 96000:
            offset_max = gmax_calc(25.7f, 25.7f, 20.75f, 575, size, 50);
            break;
          case 192000:
            offset_max = gmax_calc(25.7f, 25.7f, 24.42f, 575, size, 50);
            break;
          default:
            break;
        }
        t->start = (int32_t)(offset_max / 4.0f);
        break;
      case 16:
        switch (hz) {
          case 8000:
          case 16000:
          case 24000:
          case 32000:
          case 44100:
            offset_max = gmax_calc(26.15f, 26.15f, 16.42f, 575, size, 50);
            break;
          case 48000:
            offset_max = gmax_calc(26.18f, 26.18f, 16.32f, 575, size, 50);
            break;
          default:
            break;
        }
        t->start = (int32_t)(offset_max / 2.5f);
        break;
      default:
        break;
    }
  }

  deno = OFFSET_MAX - t->start - 1;
  t->jump = (offset_max - (float)t->start) / (float)deno;
}
