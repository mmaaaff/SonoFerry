/*
 * Public encoder API: parameter handling, PCM deinterleaving, frame queueing.
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

#ifndef LHDCV5_NO_MALLOC
#include <stdlib.h>
#endif

/* ---------------- constants ---------------- */

#define LV5E_VERSION_1 1u

static const uint32_t g_bitrate_table_44k[15] = {64,   160,  192,  240,  320,
                                                 400,  480,  900,  1000, 1100,
                                                 1200, 1300, 1400, 99999, 1536000};
static const uint32_t g_bitrate_table_48k[15] = {64,   160,  192,  256,  320,
                                                 400,  500,  900,  1000, 1100,
                                                 1200, 1300, 1400, 99999, 1536000};
static const uint32_t g_bitrate_table_96k[15] = {64,   160,  192,  256,  320,
                                                 400,  500,  900,  1000, 1100,
                                                 1200, 1300, 1400, 99999, 1536000};
static const uint32_t g_bitrate_table_192k[15] = {64,   160,  192,  256,  320,
                                                  400,  500,  900,  1000, 1100,
                                                  1200, 1300, 1400, 99999, 1536000};

#define BITRATE_TABLE_LEN 15

/* Internal failures are collapsed into one code; the public API reports
 * them all as LHDC_FRET_ERROR. */
#define LV5E_INT_OK 0
#define LV5E_INT_ERR (-1)

/* ---------------- encoder parameters ---------------- */

static int params_new(lv5e_parameters_t *p, uint32_t version) {
  if (version != LV5E_VERSION_1) {
    return LV5E_INT_ERR;
  }
  memset(p, 0, sizeof(*p));
  if (lv5e_enc_context_new(&p->lhdc_enc, 2, LV5E_KHZ_MAX, 50, 0) != 0) {
    return LV5E_INT_ERR;
  }
  if (lv5e_enc_context_set_version(&p->lhdc_enc, version) != 0) {
    return LV5E_INT_ERR;
  }
  p->version = version;
  p->sample_rate = LHDC_SR_48000HZ;
  p->bits_per_sample = LHDCBT_SMPL_FMT_S24;
  p->quality_status = LHDC_QUALITY_LOW;
  p->last_bitrate = g_bitrate_table_44k[LHDC_QUALITY_LOW];
  p->actual_bitrate = p->last_bitrate * 1000;
  p->max_bitrate_inx = LHDC_QUALITY_MAX_BITRATE;
  p->min_bitrate_inx = LHDC_QUALITY_LOW0;
  p->frame_duration = LHDC_FRAME_5MS;
  p->host_mtu_size = LHDC_MTU_2MBPS;
  p->encode_interval = LHDC_ENC_INTERVAL_20MS;
  lv5e_cirbuf_new(&p->input_cbuf,
                  LV5E_MAX_QUEUE_FRAMES * LV5E_MAX_ENC_FRAME_SAMPLE * 2);
  p->bitrate_table = g_bitrate_table_44k;
  p->update_frame_info = false;
  return LV5E_INT_OK;
}

static int32_t cal_frame_size_and_frames_in_packet(lv5e_parameters_t *handle) {
  uint32_t bytes_per_sample, bytes_per_frame, target_bytes_per_second, bytes_per_second;
  float compress_rate, max_output_bytes_per_frame;
  uint32_t bytes_per_tick, frames_per_tick, max_output_bytes_per_tick, packet_per_tick;
  uint32_t max_mtu_limit;

  if (handle->bits_per_sample_ui != LHDCBT_SMPL_FMT_S16 &&
      handle->bits_per_sample_ui != LHDCBT_SMPL_FMT_S24) {
    return LHDC_FRET_CODEC_NOT_READY;
  }
  if (handle->frame_duration == LHDC_FRAME_5MS) {
    switch (handle->sample_rate) {
      case 44100:
        if (handle->samples_per_frame != 240) return LHDC_FRET_CODEC_NOT_READY;
        break;
      case 48000:
        if (handle->samples_per_frame != 240) return LHDC_FRET_CODEC_NOT_READY;
        break;
      case 96000:
        if (handle->samples_per_frame != 480) return LHDC_FRET_CODEC_NOT_READY;
        break;
      case 192000:
        if (handle->samples_per_frame != 960) return LHDC_FRET_CODEC_NOT_READY;
        break;
      default:
        return LHDC_FRET_CODEC_NOT_READY;
    }
  } else {
    return LHDC_FRET_CODEC_NOT_READY;
  }
  if (handle->encode_interval != LHDC_ENC_INTERVAL_10MS &&
      handle->encode_interval != LHDC_ENC_INTERVAL_20MS) {
    return LHDC_FRET_CODEC_NOT_READY;
  }
  if (handle->host_mtu_size < LHDC_MTU_MIN || handle->host_mtu_size > LHDC_MTU_MAX) {
    return LHDC_FRET_CODEC_NOT_READY;
  }
  bytes_per_sample = handle->bits_per_sample_ui / 8 * 2;
  bytes_per_frame = handle->samples_per_frame * bytes_per_sample;
  target_bytes_per_second = handle->actual_bitrate / 8;
  bytes_per_second = handle->sample_rate * bytes_per_sample;
  compress_rate = (float)target_bytes_per_second / (float)bytes_per_second;
  max_output_bytes_per_frame = (float)bytes_per_frame * compress_rate;
  bytes_per_tick =
      handle->sample_rate * bytes_per_sample * handle->encode_interval / 1000;
  frames_per_tick = (uint32_t)((float)bytes_per_tick / (float)bytes_per_frame + 0.5f);
  max_output_bytes_per_tick =
      (uint32_t)(max_output_bytes_per_frame * (float)frames_per_tick);
  packet_per_tick = max_output_bytes_per_tick / handle->host_mtu_size;
  packet_per_tick = (packet_per_tick == 0) ? 1 : packet_per_tick;
  handle->frame_per_packet = frames_per_tick / packet_per_tick;
  handle->max_frame_per_packet = handle->frame_per_packet;
  max_mtu_limit = handle->host_mtu_size;
  for (;;) {
    if (max_output_bytes_per_frame * (float)handle->frame_per_packet >
        (float)max_mtu_limit) {
      handle->frame_per_packet -= 1;
    } else {
      if (max_output_bytes_per_frame * (float)handle->frame_per_packet <
          (float)handle->host_mtu_size) {
        handle->target_mtu_size = (uint32_t)max_output_bytes_per_frame;
      } else {
        handle->target_mtu_size = handle->host_mtu_size / handle->frame_per_packet;
      }
      break;
    }
  }
  return LHDC_FRET_SUCCESS;
}

static int32_t read_i32_bits(const uint8_t **input, size_t bytes) {
  int smear = (int)(4 - bytes) * 8;
  uint32_t raw = 0;
  memcpy(&raw, *input, bytes); /* little-endian */
  *input += bytes;
  return (int32_t)(raw << smear) >> smear;
}

static void deinterleave24(const uint8_t *in_0, int32_t *out, size_t out_samples) {
  size_t left = 0;
  size_t right = out_samples;
  size_t i;
  for (i = 0; i < out_samples; i++) {
    out[left + i] = read_i32_bits(&in_0, 3);
    out[right + i] = read_i32_bits(&in_0, 3);
  }
}

static void deinterleave16(const uint8_t *in_0, int32_t *out, size_t out_samples) {
  size_t left = 0;
  size_t right = out_samples;
  size_t i;
  for (i = 0; i < out_samples; i++) {
    out[left + i] = read_i32_bits(&in_0, 2);
    out[right + i] = read_i32_bits(&in_0, 2);
  }
}

static uint32_t expected_samples_per_frame(uint32_t sample_rate) {
  switch (sample_rate) {
    case 44100:
    case 48000:
      return 240;
    case 96000:
      return 480;
    case 192000:
      return 960;
    default:
      return 0;
  }
}

/* Validates frame_duration + sample_rate/samples_per_frame consistency */
static int check_frame_config(const lv5e_parameters_t *p) {
  uint32_t expect;
  if (p->frame_duration != LHDC_FRAME_5MS) {
    return LV5E_INT_ERR;
  }
  expect = expected_samples_per_frame(p->sample_rate);
  if (expect == 0 || p->samples_per_frame != expect) {
    return LV5E_INT_ERR;
  }
  return LV5E_INT_OK;
}

static int params_init(lv5e_parameters_t *p, uint32_t sampling_freq,
                       uint32_t bits_per_sample, uint32_t bitrate_inx,
                       uint32_t frame_duration, uint32_t mtu, uint32_t interval) {
  int32_t samples_per_frame = 0;
  int32_t encoded_frame_size = 0;
  uint32_t tmp_bitrate_inx = 0;

  if (p->version != LV5E_VERSION_1) {
    return LV5E_INT_ERR;
  }
  if (sampling_freq != 44100 && sampling_freq != 48000 && sampling_freq != 96000 &&
      sampling_freq != 192000) {
    return LV5E_INT_ERR;
  }
  if (bits_per_sample != 16 && bits_per_sample != 24) {
    return LV5E_INT_ERR;
  }
  if (bitrate_inx > LHDC_QUALITY_AUTO) {
    return LV5E_INT_ERR;
  }
  if (frame_duration != 25 && frame_duration != LHDC_FRAME_5MS) {
    return LV5E_INT_ERR;
  }
  if (mtu < LHDC_MTU_MIN || mtu > LHDC_MTU_MAX) {
    return LV5E_INT_ERR;
  }
  if (interval != LHDC_ENC_INTERVAL_10MS && interval != LHDC_ENC_INTERVAL_20MS) {
    return LV5E_INT_ERR;
  }
  if (p->min_bitrate_inx > LHDC_QUALITY_LOW) {
    return LV5E_INT_ERR;
  }
  if (p->max_bitrate_inx < LHDC_QUALITY_LOW ||
      p->max_bitrate_inx > LHDC_QUALITY_MAX_BITRATE) {
    return LV5E_INT_ERR;
  }
  if (p->min_bitrate_inx > p->max_bitrate_inx) {
    return LV5E_INT_ERR;
  }
  switch (sampling_freq) {
    case 44100:
      p->bitrate_table = g_bitrate_table_44k;
      break;
    case 96000:
      p->bitrate_table = g_bitrate_table_96k;
      break;
    case 192000:
      p->bitrate_table = g_bitrate_table_192k;
      break;
    default:
      p->bitrate_table = g_bitrate_table_48k;
      break;
  }
  p->quality_status = bitrate_inx;
  if (bitrate_inx < LHDC_QUALITY_AUTO) {
    tmp_bitrate_inx = bitrate_inx;
    if ((int32_t)tmp_bitrate_inx < (int32_t)p->min_bitrate_inx) {
      tmp_bitrate_inx = p->min_bitrate_inx;
    }
    if ((int32_t)tmp_bitrate_inx > (int32_t)p->max_bitrate_inx) {
      tmp_bitrate_inx = p->max_bitrate_inx;
    }
    p->last_bitrate = p->bitrate_table[tmp_bitrate_inx];
    p->quality_status = tmp_bitrate_inx;
  } else if (bitrate_inx == LHDC_QUALITY_AUTO) {
    tmp_bitrate_inx = LHDC_QUALITY_LOW;
    if ((int32_t)tmp_bitrate_inx < (int32_t)p->min_bitrate_inx) {
      tmp_bitrate_inx = p->min_bitrate_inx;
    }
    if ((int32_t)tmp_bitrate_inx > (int32_t)p->max_bitrate_inx) {
      tmp_bitrate_inx = p->max_bitrate_inx;
    }
    p->last_bitrate = p->bitrate_table[tmp_bitrate_inx];
  }
  p->sample_rate = sampling_freq;
  p->bits_per_sample_ui = bits_per_sample;
  p->bits_per_sample = bits_per_sample;
  p->frame_duration = frame_duration;
  p->host_mtu_size = mtu;
  p->encode_interval = interval;
  p->max_frame_per_interval = interval * 10 / frame_duration;
  lv5e_cirbuf_reset(&p->input_cbuf);
  if (lv5e_enc_init(2, (int32_t)p->bits_per_sample, (int32_t)sampling_freq,
                    (int32_t)frame_duration, (int32_t)(p->last_bitrate * 1000),
                    &p->lhdc_enc) != 0) {
    return LV5E_INT_ERR;
  }
  lv5e_enc_get_samples_per_frame(&samples_per_frame, &p->lhdc_enc);
  p->samples_per_frame = (uint32_t)samples_per_frame;
  if (check_frame_config(p) != LV5E_INT_OK) {
    return LV5E_INT_ERR;
  }
  lv5e_enc_get_encoded_frame_size(&encoded_frame_size, &p->lhdc_enc);
  p->encoded_frame_size = (uint32_t)encoded_frame_size;
  p->actual_bitrate = p->encoded_frame_size * 8 * 10000 / p->frame_duration;
  if (p->sample_rate == 44100) {
    p->actual_bitrate = (uint32_t)((float)p->actual_bitrate * (float)0.91875);
  }
  p->update_frame_info = false;
  cal_frame_size_and_frames_in_packet(p);
  return LV5E_INT_OK;
}

static int encoder_get_bitrate(uint32_t bitrate_inx, const uint32_t *bitrate_table,
                               uint32_t *out) {
  if (bitrate_inx >= BITRATE_TABLE_LEN) {
    return LV5E_INT_ERR;
  }
  *out = bitrate_table[bitrate_inx];
  return LV5E_INT_OK;
}

static int encoder_get_bitrate_inx(uint32_t bitrate, const uint32_t *bitrate_table,
                                   uint32_t *out) {
  uint32_t index = 0;
  if (bitrate > bitrate_table[BITRATE_TABLE_LEN - 1]) {
    return LV5E_INT_ERR;
  }
  while (index < BITRATE_TABLE_LEN) {
    if (bitrate_table[index] >= bitrate) {
      break;
    }
    index += 1;
  }
  *out = index;
  return LV5E_INT_OK;
}

static int encoder_set_target_bitrate_inx(lv5e_parameters_t *lhdc, uint32_t bitrate_inx) {
  uint32_t last_bitrate_inx;
  if (bitrate_inx > LHDC_QUALITY_MAX_BITRATE) {
    return LV5E_INT_ERR;
  }
  if (encoder_get_bitrate_inx(lhdc->last_bitrate, lhdc->bitrate_table,
                              &last_bitrate_inx) != LV5E_INT_OK) {
    return LV5E_INT_ERR;
  }
  if (bitrate_inx != last_bitrate_inx) {
    if (encoder_get_bitrate(bitrate_inx, lhdc->bitrate_table, &lhdc->last_bitrate) !=
        LV5E_INT_OK) {
      return LV5E_INT_ERR;
    }
    lhdc->update_frame_info = true;
  }
  return LV5E_INT_OK;
}

static int encoder_set_max_bitrate_inx(lv5e_parameters_t *lhdc, uint32_t max_bitrate_inx) {
  if (max_bitrate_inx < LHDC_QUALITY_LOW || max_bitrate_inx > LHDC_QUALITY_MAX_BITRATE) {
    return LV5E_INT_ERR;
  }
  if (max_bitrate_inx != lhdc->max_bitrate_inx) {
    uint32_t upd_max_bitrate;
    lhdc->max_bitrate_inx = max_bitrate_inx;
    if (lhdc->quality_status < LHDC_QUALITY_AUTO &&
        lhdc->quality_status > lhdc->max_bitrate_inx) {
      /* savitech: for downgrade target bitrate limited by max bitrate */
      lhdc->quality_status = lhdc->max_bitrate_inx;
    }
    if (encoder_get_bitrate(lhdc->max_bitrate_inx, lhdc->bitrate_table,
                            &upd_max_bitrate) != LV5E_INT_OK) {
      return LV5E_INT_ERR;
    }
    if (lhdc->last_bitrate > upd_max_bitrate) {
      if (encoder_set_target_bitrate_inx(lhdc, lhdc->max_bitrate_inx) != LV5E_INT_OK) {
        return LV5E_INT_ERR;
      }
    }
  }
  return LV5E_INT_OK;
}

static int encoder_set_min_bitrate_inx(lv5e_parameters_t *lhdc, uint32_t min_bitrate_inx) {
  if (min_bitrate_inx > LHDC_QUALITY_LOW) {
    return LV5E_INT_ERR;
  }
  if (min_bitrate_inx != lhdc->min_bitrate_inx) {
    uint32_t upd_min_bitrate;
    lhdc->min_bitrate_inx = min_bitrate_inx;
    if (lhdc->quality_status < LHDC_QUALITY_AUTO &&
        lhdc->quality_status < lhdc->min_bitrate_inx) {
      lhdc->quality_status = lhdc->min_bitrate_inx;
    }
    if (encoder_get_bitrate(lhdc->min_bitrate_inx, lhdc->bitrate_table,
                            &upd_min_bitrate) != LV5E_INT_OK) {
      return LV5E_INT_ERR;
    }
    if (lhdc->last_bitrate < upd_min_bitrate) {
      if (encoder_set_target_bitrate_inx(lhdc, lhdc->min_bitrate_inx) != LV5E_INT_OK) {
        return LV5E_INT_ERR;
      }
    }
  }
  return LV5E_INT_OK;
}

static int encoder_get_frame_len(const lv5e_parameters_t *lhdc, uint32_t *out) {
  if (check_frame_config(lhdc) != LV5E_INT_OK) {
    return LV5E_INT_ERR;
  }
  *out = lhdc->samples_per_frame;
  return LV5E_INT_OK;
}

/*
 * Encode one PCM frame.
 * Returns LV5E_INT_OK, LV5E_INT_ERR, or LHDC_FRET_BUF_NOT_ENOUGH when the
 * caller's output buffer is too small for a completed packet.
 */
static int encoder_encode(lv5e_parameters_t *lhdc, const uint8_t *in_0, size_t in_len,
                          uint8_t *out, size_t out_len, uint32_t *written_bytes,
                          uint32_t *out_frames) {
  uint32_t ch_num = 2;
  uint32_t out_frames_cnt = 0;
  int32_t encoded_bytes = 0;
  int32_t encoded_frame_size = 0;
  uint32_t samples_per_frame;
  lv5e_cirbuf_t *cbuf;
  uint32_t frame_per_packet;
  uint32_t bytes_per_frame_in, bytes_per_frame;
  uint8_t *out_tmp;
  uint32_t enc_bytes_cnt = 0;
  size_t item_cnt;

  *out_frames = 0;
  *written_bytes = 0;
  if (lhdc->version != LV5E_VERSION_1) {
    return LV5E_INT_ERR;
  }
  samples_per_frame = lhdc->samples_per_frame;
  if (check_frame_config(lhdc) != LV5E_INT_OK) {
    return LV5E_INT_ERR;
  }
  cbuf = &lhdc->input_cbuf;
  if (lhdc->update_frame_info) {
    int32_t predict_to_update_new_bitrate = 0;
    lhdc->update_frame_info = false;
    if (lv5e_cirbuf_len(cbuf) == 0) {
      predict_to_update_new_bitrate = 1;
    }
    lhdc->update_frame_info = (predict_to_update_new_bitrate != 1);
    if (predict_to_update_new_bitrate == 1) {
      if (lv5e_enc_set_bitrate((int32_t)(lhdc->last_bitrate * 1000), &lhdc->lhdc_enc) !=
          0) {
        return LV5E_INT_ERR;
      }
      lv5e_enc_get_encoded_frame_size(&encoded_frame_size, &lhdc->lhdc_enc);
      lhdc->encoded_frame_size = (uint32_t)encoded_frame_size;
      lhdc->actual_bitrate = lhdc->encoded_frame_size * 8 * 10000 / lhdc->frame_duration;
      if (lhdc->sample_rate == 44100) {
        lhdc->actual_bitrate = (uint32_t)((float)lhdc->actual_bitrate * (float)0.91875);
      }
      cal_frame_size_and_frames_in_packet(lhdc);
    }
  }
  frame_per_packet = lhdc->max_frame_per_packet;
  if (frame_per_packet == 0 || frame_per_packet > lhdc->max_frame_per_interval) {
    return LV5E_INT_ERR;
  }
  encoded_frame_size = (int32_t)lhdc->encoded_frame_size;
  if (encoded_frame_size <= 0 || encoded_frame_size >= (int32_t)LHDC_MTU_3MBPS) {
    return LV5E_INT_ERR;
  }
  bytes_per_frame_in = samples_per_frame * ch_num * lhdc->bits_per_sample / 8;
  bytes_per_frame = samples_per_frame * ch_num * (uint32_t)sizeof(int32_t);
  if (in_len < bytes_per_frame_in ||
      sizeof(lhdc->enc_in_buf) < (size_t)bytes_per_frame) {
    return LV5E_INT_ERR; /* BufTooSmall */
  }
  if (lhdc->bits_per_sample_ui == LHDCBT_SMPL_FMT_S24) {
    deinterleave24(in_0, lhdc->enc_in_buf, samples_per_frame);
  } else if (lhdc->bits_per_sample_ui == LHDCBT_SMPL_FMT_S16) {
    deinterleave16(in_0, lhdc->enc_in_buf, samples_per_frame);
  } else {
    return LV5E_INT_ERR;
  }
  out_tmp = (uint8_t *)lhdc->enc_out_buf;
  lv5e_enc_encode(lhdc->enc_in_buf, out_tmp, &encoded_bytes, &lhdc->lhdc_enc);
  item_cnt = lv5e_cirbuf_put(cbuf, out_tmp, (size_t)encoded_bytes);
  if ((uint32_t)item_cnt >= lhdc->frame_per_packet) {
    size_t queued = lv5e_cirbuf_len(cbuf);
    if (out_len < queued) {
      return LHDC_FRET_BUF_NOT_ENOUGH;
    }
    out_frames_cnt = (uint32_t)item_cnt;
    enc_bytes_cnt = (uint32_t)queued;
    lv5e_cirbuf_get(cbuf, out, queued);
  }
  *written_bytes = enc_bytes_cnt;
  *out_frames = out_frames_cnt;
  return LV5E_INT_OK;
}

/* ---------------- public API ---------------- */

#define LHDC_ENC_TYPE_LHDC 1u

size_t lhdcv5_enc_context_size(void) { return sizeof(struct lhdcv5_enc); }

lhdcv5_enc_t *lhdcv5_enc_setup_mem(void *mem, uint32_t version) {
  lhdcv5_enc_t *h = (lhdcv5_enc_t *)mem;
  if (mem == NULL) {
    return NULL;
  }
  if (params_new(&h->enc, version) != LV5E_INT_OK) {
    return NULL;
  }
  h->enc_type = LHDC_ENC_TYPE_LHDC;
  h->err = 0;
  return h;
}

#ifndef LHDCV5_NO_MALLOC
lhdcv5_enc_t *lhdcv5_enc_new(uint32_t version) {
  void *mem = malloc(sizeof(struct lhdcv5_enc));
  lhdcv5_enc_t *h;
  if (mem == NULL) {
    return NULL;
  }
  h = lhdcv5_enc_setup_mem(mem, version);
  if (h == NULL) {
    free(mem);
  }
  return h;
}

void lhdcv5_enc_free(lhdcv5_enc_t *h) { free(h); }
#endif

int32_t lhdcv5_enc_init_encoder(lhdcv5_enc_t *h, uint32_t sampling_freq,
                                uint32_t bits_per_sample, uint32_t bitrate_inx,
                                uint32_t mtu, uint32_t interval) {
  uint32_t frame_duration = LHDC_FRAME_5MS;
  uint32_t frame_len;
  if (h == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  if (sampling_freq != LHDC_SR_44100HZ && sampling_freq != LHDC_SR_48000HZ &&
      sampling_freq != LHDC_SR_96000HZ && sampling_freq != LHDC_SR_192000HZ) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (bits_per_sample != LHDCBT_SMPL_FMT_S16 && bits_per_sample != LHDCBT_SMPL_FMT_S24) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (bitrate_inx > LHDC_QUALITY_AUTO) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (frame_duration != LHDC_FRAME_5MS) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (mtu < LHDC_MTU_MIN || mtu > LHDC_MTU_MAX) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (interval != LHDC_ENC_INTERVAL_10MS && interval != LHDC_ENC_INTERVAL_20MS) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (h->enc_type != LHDC_ENC_TYPE_LHDC) {
    return LHDC_FRET_INVALID_CODEC;
  }
  if (params_init(&h->enc, sampling_freq, bits_per_sample, bitrate_inx, frame_duration,
                  mtu, interval) != LV5E_INT_OK) {
    return LHDC_FRET_ERROR;
  }
  h->enc.frame_duration = frame_duration;
  if (encoder_get_frame_len(&h->enc, &frame_len) != LV5E_INT_OK) {
    return LHDC_FRET_ERROR;
  }
  return LHDC_FRET_SUCCESS;
}

int32_t lhdcv5_enc_get_block_size(const lhdcv5_enc_t *h, uint32_t *samples_per_frame) {
  if (h == NULL || samples_per_frame == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  if (h->enc_type != LHDC_ENC_TYPE_LHDC) {
    return LHDC_FRET_INVALID_CODEC;
  }
  if (encoder_get_frame_len(&h->enc, samples_per_frame) != LV5E_INT_OK) {
    return LHDC_FRET_ERROR;
  }
  return LHDC_FRET_SUCCESS;
}

int32_t lhdcv5_enc_encode(lhdcv5_enc_t *h, const uint8_t *in_pcm, size_t in_pcm_len,
                          uint8_t *out_buf, size_t out_buf_len, uint32_t *written_bytes,
                          uint32_t *written_frames) {
  int ret;
  if (h == NULL || in_pcm == NULL || out_buf == NULL || written_bytes == NULL ||
      written_frames == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  if (h->enc_type != LHDC_ENC_TYPE_LHDC) {
    return LHDC_FRET_INVALID_CODEC;
  }
  ret = encoder_encode(&h->enc, in_pcm, in_pcm_len, out_buf, out_buf_len, written_bytes,
                       written_frames);
  if (ret == LHDC_FRET_BUF_NOT_ENOUGH) {
    return LHDC_FRET_BUF_NOT_ENOUGH;
  }
  if (ret != LV5E_INT_OK) {
    return LHDC_FRET_ERROR;
  }
  return LHDC_FRET_SUCCESS;
}

int32_t lhdcv5_enc_set_bitrate_index(lhdcv5_enc_t *h, uint32_t bitrate_inx,
                                     bool update_quality_status) {
  uint32_t upd_bitrate_inx;
  if (h == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  if (bitrate_inx > LHDC_QUALITY_AUTO) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (h->enc_type != LHDC_ENC_TYPE_LHDC) {
    return LHDC_FRET_INVALID_CODEC;
  }
  if (bitrate_inx == LHDC_QUALITY_AUTO) {
    upd_bitrate_inx = LHDC_QUALITY_LOW;
  } else {
    upd_bitrate_inx = bitrate_inx;
  }
  if (upd_bitrate_inx < h->enc.min_bitrate_inx) {
    upd_bitrate_inx = h->enc.min_bitrate_inx;
  }
  if (upd_bitrate_inx > h->enc.max_bitrate_inx) {
    upd_bitrate_inx = h->enc.max_bitrate_inx;
  }
  if (update_quality_status) {
    if (bitrate_inx == LHDC_QUALITY_AUTO) {
      h->enc.quality_status = LHDC_QUALITY_AUTO;
    } else {
      h->enc.quality_status = upd_bitrate_inx;
    }
  }
  if (encoder_set_target_bitrate_inx(&h->enc, upd_bitrate_inx) != LV5E_INT_OK) {
    return LHDC_FRET_ERROR;
  }
  return LHDC_FRET_SUCCESS;
}

int32_t lhdcv5_enc_set_max_bitrate_index(lhdcv5_enc_t *h, uint32_t max_bitrate_inx) {
  if (h == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  if (max_bitrate_inx < LHDC_QUALITY_LOW || max_bitrate_inx > LHDC_QUALITY_MAX_BITRATE) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (h->enc_type != LHDC_ENC_TYPE_LHDC) {
    return LHDC_FRET_INVALID_CODEC;
  }
  if (encoder_set_max_bitrate_inx(&h->enc, max_bitrate_inx) != LV5E_INT_OK) {
    return LHDC_FRET_ERROR;
  }
  return LHDC_FRET_SUCCESS;
}

int32_t lhdcv5_enc_set_min_bitrate_index(lhdcv5_enc_t *h, uint32_t min_bitrate_inx) {
  if (h == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  if (min_bitrate_inx > LHDC_QUALITY_LOW) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (h->enc_type != LHDC_ENC_TYPE_LHDC) {
    return LHDC_FRET_INVALID_CODEC;
  }
  if (encoder_set_min_bitrate_inx(&h->enc, min_bitrate_inx) != LV5E_INT_OK) {
    return LHDC_FRET_ERROR;
  }
  return LHDC_FRET_SUCCESS;
}

int32_t lhdcv5_enc_get_bitrate_index(const lhdcv5_enc_t *h, uint32_t bitrate_kbps,
                                     uint32_t *bitrate_inx) {
  uint32_t inx;
  if (h == NULL || bitrate_inx == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  if (bitrate_kbps > h->enc.bitrate_table[BITRATE_TABLE_LEN - 1]) {
    return LHDC_FRET_INVALID_INPUT_PARAM;
  }
  if (encoder_get_bitrate_inx(bitrate_kbps, h->enc.bitrate_table, &inx) != LV5E_INT_OK) {
    return LHDC_FRET_ERROR;
  }
  *bitrate_inx = inx;
  return LHDC_FRET_SUCCESS;
}

int32_t lhdcv5_enc_get_last_bitrate(const lhdcv5_enc_t *h, uint32_t *bitrate_kbps) {
  if (h == NULL || bitrate_kbps == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  *bitrate_kbps = h->enc.last_bitrate;
  return LHDC_FRET_SUCCESS;
}

int32_t lhdcv5_enc_get_quality_mode(const lhdcv5_enc_t *h, uint32_t *quality_status) {
  if (h == NULL || quality_status == NULL) {
    return LHDC_FRET_INVALID_HANDLE_CB;
  }
  *quality_status = h->enc.quality_status;
  return LHDC_FRET_SUCCESS;
}
