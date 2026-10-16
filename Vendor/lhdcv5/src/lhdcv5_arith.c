/*
 * Adaptive range coder with a small ring-buffered symbol history.
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

#define HIGH_BYTE_ONE 0x01000000u

/* ---------------- ring buffer ---------------- */

static uint8_t ring_peek(lv5e_ring_buf_t *r) { return r->buf[r->idx]; }

static void ring_push(lv5e_ring_buf_t *r, uint8_t val) {
  r->buf[r->idx] = val;
  r->idx += 1;
  if (r->idx >= r->max_shifts) {
    r->idx = 0;
  }
}

/* true for shift successful, false for no more room */
static bool ring_shift(lv5e_ring_buf_t *r, uint8_t val) {
  if (r->shifts_done >= r->max_shifts) {
    return false;
  }
  r->buf[r->shifts_done] = val;
  r->shifts_done += 1;
  return true;
}

static void ring_reset(lv5e_ring_buf_t *r, int32_t max_shifts) {
  r->shifts_done = 0;
  r->max_shifts = max_shifts;
  r->idx = 0;
}

/* ---------------- symbol frequency model ---------------- */

static uint32_t scale_of_probility(uint32_t deno) { return 0x80000000u / deno; }

static void symbol_data_load(lv5e_symbol_data_t *s, const uint32_t *count, size_t len) {
  memcpy(s->input, count, len * sizeof(uint32_t));
  s->symbol_num = (uint8_t)len;
}

static void symbol_data_calc(lv5e_symbol_data_t *s) {
  size_t symbol_num = s->symbol_num;
  uint32_t sum = 0;
  size_t i;
  for (i = 0; i < symbol_num; i++) {
    sum += s->input[i];
    s->cdf[i + 1] = sum;
  }
  for (i = 0; i < symbol_num; i++) {
    s->buf_3[i] = s->input[i] + (s->input[i] >> 5);
  }
  {
    uint32_t weight = scale_of_probility(sum);
    for (i = 0; i < symbol_num; i++) {
      s->cdf[i + 1] *= weight;
      s->cdf[i + 1] >>= 31 - 15;
    }
  }
}

/* ---------------- encoder ---------------- */

void lv5e_arith_enc_new(lv5e_arith_enc_t *e, lv5e_arith_base_t *base, uint8_t *out,
                        size_t out_len) {
  base->valid_bits = 0xffffffffu;
  base->big_digit = 0;
  memset(&base->arith, 0, sizeof(base->arith));
  memset(&base->ring, 0, sizeof(base->ring));
  base->write_head = 0;
  e->base = base;
  e->out = out;
  e->out_len = out_len;
}

static void enc_symbol_frequency(lv5e_arith_enc_t *e, uint32_t c) {
  lv5e_symbol_data_t *a = &e->base->arith;
  size_t i = ring_peek(&e->base->ring);
  if (a->input[i] > 1) {
    a->input[i] -= 1;
  }
  a->input[c] += 1;
  if (a->input[c] >= a->buf_3[c]) {
    symbol_data_calc(a);
  }
  ring_push(&e->base->ring, (uint8_t)c);
}

static int enc_write(lv5e_arith_enc_t *e, uint8_t val) {
  if (e->base->write_head >= e->out_len) {
    return -1;
  }
  e->out[e->base->write_head] = val;
  e->base->write_head += 1;
  return 0;
}

static void enc_add_with_overflow(lv5e_arith_enc_t *e, uint32_t val) {
  uint32_t acc = e->base->big_digit + val;
  bool overflow = acc < e->base->big_digit; /* wrapped */
  if (overflow) {
    size_t carry_idx = e->base->write_head - 1;
    while (e->out[carry_idx] == 0xff) {
      e->out[carry_idx] = 0;
      carry_idx -= 1;
    }
    e->out[carry_idx] += 1;
  }
  e->base->big_digit = acc;
}

static int enc_flush(lv5e_arith_enc_t *e) {
  while (e->base->valid_bits < HIGH_BYTE_ONE) {
    if (enc_write(e, (uint8_t)(e->base->big_digit >> 24)) != 0) {
      return -1;
    }
    e->base->valid_bits <<= 8;
    e->base->big_digit <<= 8;
  }
  return 0;
}

static int enc_symbol_1(lv5e_arith_enc_t *e, uint32_t symbol) {
  uint32_t len = e->base->valid_bits >> 15;
  uint32_t lower = len * e->base->arith.cdf[symbol];
  enc_add_with_overflow(e, lower);
  e->base->valid_bits = len * e->base->arith.cdf[symbol + 1] - lower;
  return enc_flush(e);
}

static void enc_symbol_2(lv5e_arith_enc_t *e, uint32_t symbol) {
  lv5e_symbol_data_t *a = &e->base->arith;
  a->input[symbol] += 1;
  if (a->buf_3[symbol] <= a->input[symbol]) {
    symbol_data_calc(a);
  }
}

void lv5e_arith_program(lv5e_arith_enc_t *e, const uint32_t *count, size_t count_len,
                        int32_t shifting_num) {
  symbol_data_load(&e->base->arith, count, count_len);
  symbol_data_calc(&e->base->arith);
  ring_reset(&e->base->ring, shifting_num);
}

int lv5e_arith_symbol_3(lv5e_arith_enc_t *e, uint32_t symbol) {
  if (enc_symbol_1(e, symbol) != 0) {
    return -1;
  }
  if (ring_shift(&e->base->ring, (uint8_t)symbol)) {
    enc_symbol_2(e, symbol);
  } else {
    enc_symbol_frequency(e, symbol);
  }
  return 0;
}

int32_t lv5e_arith_clear(lv5e_arith_enc_t *e, lv5e_bitout_t *bo) {
  if (e->base->valid_bits <= 2 * HIGH_BYTE_ONE) {
    enc_add_with_overflow(e, HIGH_BYTE_ONE >> 1);
    e->base->valid_bits = HIGH_BYTE_ONE >> 9;
  } else {
    enc_add_with_overflow(e, HIGH_BYTE_ONE);
    e->base->valid_bits = HIGH_BYTE_ONE >> 1;
  }
  if (enc_flush(e) != 0) {
    return -1;
  }
  if (lv5e_bitout_write_bytes(bo, e->out, e->base->write_head) != 0) {
    return -1;
  }
  return (int32_t)e->base->write_head;
}

/* ---------------- size estimation ---------------- */

static uint32_t inverse_total(uint32_t t) { return 0x10000u / t; }

static float bit_esti(uint32_t count, uint32_t inverse_all) {
  float vxf = (float)(count * inverse_all) * (1.0f / 65536.0f);
  uint32_t bits;
  float y;
  memcpy(&bits, &vxf, 4);
  y = (float)bits;
  y *= 1.1920929e-7f;
  return 126.942696f - y;
}

int32_t lv5e_arith_esti(const uint8_t *udata8, size_t udata8_len,
                        const uint32_t *counting_table, size_t table_len) {
  uint32_t data_count[5] = {0, 0, 0, 0, 0};
  uint32_t all = 0;
  uint32_t inverse_all;
  float est_sum = 0.0f;
  size_t i;
  for (i = 0; i < table_len; i++) {
    data_count[i] = counting_table[i];
    all += counting_table[i];
  }
  for (i = 0; i < udata8_len; i++) {
    data_count[udata8[i]] += 1;
  }
  all += (uint32_t)udata8_len;
  inverse_all = inverse_total(all);
  for (i = 0; i < table_len; i++) {
    float est_bits = bit_esti(data_count[i], inverse_all);
    est_sum += (float)(data_count[i] - counting_table[i]) * est_bits;
  }
  return (int32_t)est_sum;
}
