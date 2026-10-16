/*
 * Byte circular buffer that queues encoded frames until a packet is full.
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

void lv5e_cirbuf_new(lv5e_cirbuf_t *c, size_t len) {
  c->idx = 0;
  c->odx = 0;
  c->s_len = 0;
  c->max_len = len;
  c->r_len = len;
  c->item_cnt = 0;
  memset(c->cbuf, 0, sizeof(c->cbuf));
}

void lv5e_cirbuf_reset(lv5e_cirbuf_t *c) {
  c->idx = 0;
  c->odx = 0;
  c->s_len = 0;
  c->r_len = c->max_len;
}

size_t lv5e_cirbuf_len(const lv5e_cirbuf_t *c) { return c->s_len; }

size_t lv5e_cirbuf_empty_len(const lv5e_cirbuf_t *c) { return c->r_len; }

void lv5e_cirbuf_get(lv5e_cirbuf_t *c, uint8_t *buf, size_t buf_len) {
  size_t t_len, read_len, n;
  c->item_cnt = 0;
  if (buf_len == 0 || c->s_len == 0) {
    return;
  }
  if (buf_len > c->s_len) {
    buf_len = c->s_len;
  }
  t_len = buf_len;
  read_len = t_len;
  n = c->max_len - c->odx;
  if (n <= t_len) {
    memcpy(buf, c->cbuf + c->odx, n);
    buf += n;
    t_len -= n;
    c->odx = 0;
  }
  if (t_len != 0) {
    memcpy(buf, c->cbuf + c->odx, t_len);
    c->odx += t_len;
  }
  c->s_len -= read_len;
  c->r_len += read_len;
}

size_t lv5e_cirbuf_put(lv5e_cirbuf_t *c, const uint8_t *buf, size_t buf_len) {
  size_t t_len, write_len, n;
  c->item_cnt += 1;
  if (c->r_len == 0 || buf_len == 0) {
    return 0;
  }
  if (buf_len > c->r_len) {
    buf_len = c->r_len;
  }
  t_len = buf_len;
  write_len = t_len;
  n = c->max_len - c->idx;
  if (n <= t_len) {
    memcpy(c->cbuf + c->idx, buf, n);
    buf += n;
    t_len -= n;
    c->idx = 0;
  }
  if (t_len != 0) {
    memcpy(c->cbuf + c->idx, buf, t_len);
    c->idx += t_len;
  }
  c->s_len += write_len;
  c->r_len -= write_len;
  return c->item_cnt;
}
