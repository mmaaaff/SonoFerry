/*
 * Math helpers: fast power-of-2 / sqrt approximations and a log2 table.
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

static inline float bits_to_f32(uint32_t u) {
  float f;
  memcpy(&f, &u, 4);
  return f;
}

static inline uint32_t f32_to_bits(float f) {
  uint32_t u;
  memcpy(&u, &f, 4);
  return u;
}

float lv5e_power_of_2(float x) {
  float offset = (x < 0.0f) ? 1.0f : 0.0f;
  float clip = (x < -126.0f) ? -126.0f : x;
  int32_t w = (int32_t)clip;
  float z = clip - (float)w + offset;
  uint32_t bits = (uint32_t)((float)(1u << 23) *
                             (clip + 121.274055f + 27.728024f / (4.8425255f - z) -
                              1.4901291f * z));
  return bits_to_f32(bits);
}

float lv5e_sqrtf(float x) {
  const float threehalfs = 1.5f;
  float x2 = x * 0.5f;
  float y = x;
  uint32_t i = f32_to_bits(y);
  i = 0x5f3759df - (i >> 1);
  y = bits_to_f32(i);
  y = y * (threehalfs - x2 * y * y);
  return 1.0f / y;
}

static const uint8_t LOG2_256_TABLE[256] = {
    0, 0, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7};

uint8_t lv5e_log_2(uint32_t val) {
  if (val == 0) {
    return 0;
  } else if (val <= 0xff) {
    return (uint8_t)(LOG2_256_TABLE[val] + 1);
  } else if (val <= 0xffff) {
    return (uint8_t)(LOG2_256_TABLE[val >> 8] + 9);
  } else if (val <= 0xffffff) {
    return (uint8_t)(LOG2_256_TABLE[val >> 16] + 17);
  } else {
    return (uint8_t)(LOG2_256_TABLE[val >> 24] + 25);
  }
}
