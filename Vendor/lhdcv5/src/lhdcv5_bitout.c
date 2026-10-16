/*
 * Bit-level output writer over a 32-bit word buffer.
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

void lv5e_bitout_new(lv5e_bitout_t *b, uint32_t *out, size_t out_words) {
  b->out = out;
  b->out_words = out_words;
  b->write_head = 0;
  b->enc_r_d32_l = 0;
  b->enc_r_num = 0;
}

static void bitout_push(lv5e_bitout_t *b, uint32_t val) {
  b->out[b->write_head] = val;
  b->write_head += 1;
}

static bool bitout_full(const lv5e_bitout_t *b) { return b->write_head >= b->out_words; }

static uint32_t bswap32(uint32_t v) {
  return ((v & 0xff000000u) >> 24) | ((v & 0x00ff0000u) >> 8) | ((v & 0x0000ff00u) << 8) |
         ((v & 0x000000ffu) << 24);
}

int lv5e_bitout_write_bits(lv5e_bitout_t *b, uint32_t data, uint32_t bit_len) {
  uint32_t bit_len_l;
  int32_t offset;
  if (bit_len > 32) {
    return -1;
  }
  if (bit_len == 0) {
    return 0;
  }
  bit_len_l = 32u - b->enc_r_num;
  offset = (int32_t)(bit_len - bit_len_l);
  if (offset >= 0 && bitout_full(b)) {
    return -1;
  }
  data &= 0xffffffffu >> (32 - bit_len);
  if (offset >= 0 && b->enc_r_num != 0) {
    uint32_t mem_data = b->enc_r_d32_l << bit_len_l;
    mem_data |= data >> offset;
    bitout_push(b, bswap32(mem_data));
    b->enc_r_num = (uint32_t)offset;
    b->enc_r_d32_l = data;
  } else if (offset >= 0 && b->enc_r_num == 0) {
    bitout_push(b, bswap32(data));
  } else {
    b->enc_r_d32_l <<= bit_len;
    b->enc_r_d32_l |= data;
    b->enc_r_num += bit_len;
  }
  return 0;
}

int lv5e_bitout_write_bytes(lv5e_bitout_t *b, const uint8_t *data, size_t len) {
  size_t i = 0;
  /* If we still have data stored internally, feed byte by byte until it can
   * be flushed as a doubleword write. */
  while (b->enc_r_num != 0 && i < len) {
    if (lv5e_bitout_write_bits(b, data[i], 8) != 0) {
      return -1;
    }
    i += 1;
  }
  /* Then, feed a doubleword at a time for as long as possible (native
   * endian; the codec requires a little-endian target). */
  while (i + 4 <= len) {
    uint32_t dw;
    if (bitout_full(b)) {
      return -1;
    }
    memcpy(&dw, data + i, 4);
    bitout_push(b, dw);
    i += 4;
  }
  /* Finally, feed the remaining data in */
  while (i < len) {
    if (lv5e_bitout_write_bits(b, data[i], 8) != 0) {
      return -1;
    }
    i += 1;
  }
  return 0;
}

int lv5e_bitout_zero_pad(lv5e_bitout_t *b) {
  if ((b->enc_r_num & 7) != 0) {
    return lv5e_bitout_write_bits(b, 0, 8);
  }
  return 0;
}

int32_t lv5e_bitout_clear(lv5e_bitout_t *b) {
  uint8_t *umem8 = (uint8_t *)(b->out + b->write_head);
  size_t umem8_len = (b->out_words - b->write_head) * 4;
  uint32_t tmp_bits = 0;
  if (b->enc_r_num != 0) {
    uint32_t n;
    uint32_t i;
    tmp_bits = (b->enc_r_num + 7) / 8;
    if ((size_t)tmp_bits > umem8_len) {
      return -1;
    }
    n = b->enc_r_d32_l << (32 - b->enc_r_num);
    for (i = 0; i < tmp_bits; i++) {
      /* n little-endian bytes indexed [3 - i]: most-significant first */
      umem8[i] = (uint8_t)(n >> (24 - 8 * i));
    }
  }
  return (int32_t)(b->write_head * 4 + tmp_bits);
}
