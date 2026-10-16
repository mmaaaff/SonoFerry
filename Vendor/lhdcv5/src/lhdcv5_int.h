/*
 * LHDC V5 encoder - internal definitions.
 *
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef LHDCV5_INT_H
#define LHDCV5_INT_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdbool.h>

#include "lhdcv5_enc.h"

/* The bit-exact behaviour of the codec relies on little-endian byte order. */
#if defined(__BYTE_ORDER__) && (__BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__)
#error "lhdcv5_enc requires a little-endian target"
#endif

/* ------------------------------------------------------------------ */
/* Compile-time sizing for the worst-case config (2 ch, 192 kHz, 5 ms) */
/* ------------------------------------------------------------------ */

#ifndef LHDCV5_MAX_SAMPLE_RATE
#define LHDCV5_MAX_SAMPLE_RATE 192000
#endif

#if LHDCV5_MAX_SAMPLE_RATE == 44100 || LHDCV5_MAX_SAMPLE_RATE == 48000
#define LV5E_KHZ_MAX 48000
#elif LHDCV5_MAX_SAMPLE_RATE == 96000
#define LV5E_KHZ_MAX 96000
#elif LHDCV5_MAX_SAMPLE_RATE == 192000
#define LV5E_KHZ_MAX 192000
#else
#error "LHDCV5_MAX_SAMPLE_RATE must be 44100, 48000, 96000 or 192000"
#endif

#define LV5E_MS_MAX 50
#define LV5E_MAX_CH 2

/* max_frame_size = khz_max * ms_max / 10000 */
#define LV5E_MAX_FRAME_SIZE (LV5E_KHZ_MAX * LV5E_MS_MAX / 10000)
#define LV5E_MAX_FRAME_SIZE_10MS (LV5E_MAX_FRAME_SIZE * 10)
/* max_frequency_repeating = khz_max * 20 / 10000 */
#define LV5E_MAX_FREQ_REPEATING (LV5E_KHZ_MAX * 20 / 10000)
/* max_lossy_umem8_len = 2 * max(max_frame_size_10ms, 960) */
#if LV5E_MAX_FRAME_SIZE_10MS > 960
#define LV5E_MAX_LOSSY_UMEM8 (2 * LV5E_MAX_FRAME_SIZE_10MS)
#else
#define LV5E_MAX_LOSSY_UMEM8 (2 * 960)
#endif
/* fdata_enc_buffer_struct::count_calc(50, khz_max, max_frame_size) */
#define LV5E_LOSSY_FDATA_LEN (LV5E_KHZ_MAX * 100 / 10000)
#define LV5E_NFFT_MAX (LV5E_MAX_FRAME_SIZE / 2)

/* encoded-frame queue */
#define LV5E_MAX_QUEUE_FRAMES 4
#define LV5E_MAX_ENC_FRAME_SAMPLE 960

/* ------------------------------------------------------------------ */
/* math helpers                                                        */
/* ------------------------------------------------------------------ */

float lv5e_power_of_2(float x);
float lv5e_sqrtf(float x);
uint8_t lv5e_log_2(uint32_t val);

/* divide by 3 via inverse multiplication; slightly off for some negative
 * inputs, but the codec depends on exactly this behaviour */
static inline int32_t lv5e_div3(int32_t x) {
  return (int32_t)(((int64_t)x * 715827882LL) >> 31);
}

/* rounded division: floor((x + y/2) / y), y > 0 */
static inline int32_t lv5e_div_round(int32_t x, int32_t y) {
  int32_t a = x + y / 2;
  int32_t q = a / y; /* truncated */
  int32_t r = a - q * y;
  /* floor adjustment, deliberately written against the exact remainder: a
   * remainder-operator test here gets mis-folded into a plain sign check by
   * some optimizers (MSVC /O2), which breaks bit-exactness when r == 0 */
  q -= (int32_t)(((uint32_t)r >> 31) & (r != 0));
  return q;
}

/* wrapping i32 multiply without signed-overflow UB */
static inline int32_t lv5e_wmul(int32_t a, int32_t b) {
  return (int32_t)((uint32_t)a * (uint32_t)b);
}

/* ------------------------------------------------------------------ */
/* adaptive range coder                                                */
/* ------------------------------------------------------------------ */

typedef struct {
  uint8_t buf[128];
  int32_t idx;
  int32_t max_shifts;
  int32_t shifts_done;
} lv5e_ring_buf_t;

typedef struct {
  uint8_t symbol_num;
  uint32_t cdf[6];
  uint32_t input[5];
  uint32_t buf_3[5];
} lv5e_symbol_data_t;

typedef struct {
  uint32_t big_digit;  /* logical digit */
  uint32_t valid_bits; /* bits set-in-stone, 0 means ready */
  size_t write_head;
  lv5e_ring_buf_t ring;
  lv5e_symbol_data_t arith;
} lv5e_arith_base_t;

typedef struct {
  lv5e_arith_base_t *base;
  uint8_t *out;
  size_t out_len;
} lv5e_arith_enc_t;

struct lv5e_bitout; /* fwd */

void lv5e_arith_enc_new(lv5e_arith_enc_t *e, lv5e_arith_base_t *base, uint8_t *out,
                        size_t out_len);
void lv5e_arith_program(lv5e_arith_enc_t *e, const uint32_t *count, size_t count_len,
                        int32_t shifting_num);
/* returns 0 on success, -1 on output overflow */
int lv5e_arith_symbol_3(lv5e_arith_enc_t *e, uint32_t symbol);
/* returns written byte count (>=0), or -1 on error */
int32_t lv5e_arith_clear(lv5e_arith_enc_t *e, struct lv5e_bitout *bo);
int32_t lv5e_arith_esti(const uint8_t *udata8, size_t udata8_len,
                        const uint32_t *counting_table, size_t table_len);

/* ------------------------------------------------------------------ */
/* bit-level output writer                                             */
/* ------------------------------------------------------------------ */

typedef struct lv5e_bitout {
  uint32_t *out;
  size_t out_words;
  size_t write_head;
  uint32_t enc_r_d32_l; /* bits staged */
  uint32_t enc_r_num;   /* bits valid */
} lv5e_bitout_t;

void lv5e_bitout_new(lv5e_bitout_t *b, uint32_t *out, size_t out_words);
int lv5e_bitout_write_bits(lv5e_bitout_t *b, uint32_t data, uint32_t bit_len);
int lv5e_bitout_write_bytes(lv5e_bitout_t *b, const uint8_t *data, size_t len);
int lv5e_bitout_zero_pad(lv5e_bitout_t *b);
/* returns total bytes in the output buffer, or -1 on overflow */
int32_t lv5e_bitout_clear(lv5e_bitout_t *b);

/* ------------------------------------------------------------------ */
/* fixed-point FFT (KISS FFT based)                                    */
/* ------------------------------------------------------------------ */

typedef struct {
  int32_t r;
  int32_t i;
} lv5e_complex_t;

typedef struct {
  int32_t nfft;
  int32_t inverse;
  int32_t factors[64];
  lv5e_complex_t twiddles[LV5E_NFFT_MAX];
} lv5e_fft_state_t;

void lv5e_fft_reset(lv5e_fft_state_t *st, int32_t nfft, int32_t inverse);
void lv5e_fft(lv5e_fft_state_t *cfg, const lv5e_complex_t *f_in, lv5e_complex_t *f_out);

/* ------------------------------------------------------------------ */
/* quantization level table                                            */
/* ------------------------------------------------------------------ */

typedef struct {
  float cache[512];
  int32_t start;
  float jump;
} lv5e_level_table_t;

void lv5e_level_table_init(lv5e_level_table_t *t, int32_t size, int32_t resolution,
                           int32_t hz, int32_t ms);
float lv5e_level_table_level(lv5e_level_table_t *t, int32_t offset_idx);

/* ------------------------------------------------------------------ */
/* frame header + segment settings                                     */
/* ------------------------------------------------------------------ */

typedef struct {
  float drity_bit_adding;
  int32_t segment_num_inv;
  int32_t segment_scale_jump;
  int32_t segment_scale_level;
  int32_t codeing_step_0;
  size_t segment_num;
  int32_t arith_init_0;
  int32_t arith_init_1;
  size_t segment_offset[34];
  int32_t segment_scale[34];
} lv5e_segment_settings_t;

/* returns true if `index` matched a known configuration */
bool lv5e_segment_settings_init(lv5e_segment_settings_t *s, size_t index);

enum {
  LV5E_ENC_SIZE_INDEX = 0,
  LV5E_VERSION_INDEX = 1,
  LV5E_JAS_INDEX = 2,
  LV5E_AR_INDEX = 3,
  LV5E_LARC_INDEX = 4,
  LV5E_META_INDEX = 5,
};

typedef struct {
  uint16_t info;
  uint8_t ext_data[10];
  int32_t enc_frm_len_provided;
  uint8_t enc_frm_len_need_update;
  int32_t meta_data_loop_count;
} lv5e_header_t;

void lv5e_header_set_info(lv5e_header_t *h, unsigned index, int32_t value);
int32_t lv5e_header_get_info(const lv5e_header_t *h, unsigned index);
int32_t lv5e_enc_process_header(lv5e_header_t *hdr, int32_t ch,
                                int32_t *enc_frm_len_usable, uint8_t *encoded_frame);

/* ------------------------------------------------------------------ */
/* frequency transform                                                 */
/* ------------------------------------------------------------------ */

typedef struct {
  int32_t freq_data[LV5E_MAX_FRAME_SIZE + LV5E_MAX_FREQ_REPEATING];
  int32_t fft_iv[LV5E_MAX_FRAME_SIZE];
  lv5e_complex_t fft_coef_in[LV5E_NFFT_MAX];
  lv5e_complex_t fft_coef_out[LV5E_NFFT_MAX];
} lv5e_frequency_buffers_t;

typedef struct {
  size_t offset;
  int32_t repeat_size_top[LV5E_MAX_FREQ_REPEATING * LV5E_MAX_CH];
} lv5e_repeating_channels_t;

typedef struct {
  int32_t size;
  int32_t repeating;
  int32_t offset_num;
  int32_t num1;
  int32_t num2;
  int32_t num3;
  int32_t num4;
  lv5e_fft_state_t kiss_fft_cfg;
  int32_t freqency_win[LV5E_MAX_FREQ_REPEATING];
  lv5e_complex_t pre_twid[LV5E_NFFT_MAX];
  lv5e_complex_t pos_twid[LV5E_NFFT_MAX];
  lv5e_repeating_channels_t frequency_process_ch_num;
  lv5e_frequency_buffers_t frequency_buffers;
  int32_t pos_twid_scalar_shift;
} lv5e_freq_top_t;

void lv5e_freq_top_reset(lv5e_freq_top_t *t, int32_t frequency_size, int32_t repeating,
                         int32_t sft_num);
void lv5e_enc_lossy_frequency_operation(lv5e_freq_top_t *frequency, int32_t c,
                                        int32_t *output);

/* ------------------------------------------------------------------ */
/* encoder workspace                                                   */
/* ------------------------------------------------------------------ */

typedef struct {
  int32_t fdata_q_quant[LV5E_MAX_FRAME_SIZE];
  int32_t fdata_q_quant_rem[LV5E_MAX_FRAME_SIZE];
  int32_t fdata_q_quant_bit_num[LV5E_MAX_LOSSY_UMEM8 / 2 + 1];
  uint32_t fdata_q_quant_2_symbol[LV5E_MAX_FRAME_SIZE];
  int32_t valid;
  int32_t symbol_flag;
  int32_t fdata_q_size;
  int32_t fdata_q_len;
  int32_t fdata_q_esti_len;
  int32_t fdata_q_true_len;
} lv5e_fdata_buffer_t;

typedef struct {
  int32_t lossy_fdata_buf[LV5E_LOSSY_FDATA_LEN];
  int32_t freqency_segment[32];
  int32_t lossy_fdata_ave;
  uint8_t lossy_jump_adus_parameter[31];
  int32_t lossy_jump_adus_num;
  int32_t jump_level_top;
  lv5e_fdata_buffer_t level;
} lv5e_fdata_enc_buffer_t;

typedef struct {
  int32_t offset_size;
  float offset_step;
} lv5e_fdata_ch_buffer_t;

typedef struct {
  int32_t khz_top;
  int32_t ms_top;
  int32_t pixel_num_top;
  int32_t lossy_symbol_size_top;
  int32_t freqency_ov_top;
  int32_t khz;
  int32_t resolution;
  int32_t ch_num;
  int32_t pixel_num;
  int32_t pixel_ov_num;
  int32_t ms;
  int32_t valid_num;
  int32_t fdata_quant_rem_data_size;
  int32_t fdata_quant_rem_data_size_top;
  int32_t header_data_size;
  int32_t frame_cnt;
  int32_t enc_pixel_size_byte;
  int32_t enc_pixel_size_bits;
  int32_t target_range;
  int32_t target_range_bottom;
  int32_t esti_diff_value;
  lv5e_level_table_t level_table;
  lv5e_segment_settings_t segment_setting;
  int32_t segment_cutoff;
  lv5e_freq_top_t frequency_mem;
  lv5e_fdata_ch_buffer_t fdata_ch_buffer[2];
  lv5e_fdata_enc_buffer_t fdata_enc_buffer;
  int32_t frame_count;
  uint32_t init_fq_tbl_01[3];
  uint32_t init_fq_tbl_02[3];
  int32_t power_of_2_tbl[161];
  uint32_t logarithm_by_2_tbl[64];
} lv5e_fdata_all_buffer_t;

void lv5e_fdata_all_buffer_new(lv5e_fdata_all_buffer_t *b, int32_t khz_top, int32_t ms_top,
                               int32_t max_frame_size, int32_t max_lossy_umem8_len,
                               int32_t max_freq_repeating);
int32_t lv5e_fdata_all_buffer_reset(lv5e_fdata_all_buffer_t *b, int32_t ms, int32_t khz,
                                    int32_t resolution, int32_t ch_num,
                                    size_t enc_pixel_size_byte);

/* ------------------------------------------------------------------ */
/* low-level encoder context                                           */
/* ------------------------------------------------------------------ */

typedef struct {
  size_t khz_max;
  size_t ms_max;
  size_t max_frame_size;
  size_t max_lossy_umem8_len;
  size_t max_frequency_repeating;
  lv5e_header_t hdr_s;
  lv5e_fdata_all_buffer_t ebuffer;
  lv5e_arith_base_t enc_arith_s;
  uint32_t encoded_data_ch0[171];
  uint32_t encoded_data_ch1[171];
} lv5e_enc_context_t;

/* returns 0 on success, -1 on bad config */
int lv5e_enc_context_new(lv5e_enc_context_t *ctx, size_t ch, size_t khz_max,
                         size_t ms_max, uint32_t mode);
int lv5e_enc_context_set_version(lv5e_enc_context_t *ctx, size_t version);

/* ------------------------------------------------------------------ */
/* core encode entry points                                            */
/* ------------------------------------------------------------------ */

/* return 0 on success, -1 on error */
int lv5e_enc_init(int32_t channel, int32_t resolution, int32_t khz, int32_t ms,
                  int32_t bitrate, lv5e_enc_context_t *ctx);
void lv5e_enc_get_samples_per_frame(int32_t *s_fps, lv5e_enc_context_t *ctx);
int lv5e_enc_set_bitrate(int32_t bitrate, lv5e_enc_context_t *ctx);
void lv5e_enc_get_encoded_frame_size(int32_t *encoded_frame_size, lv5e_enc_context_t *ctx);
void lv5e_enc_encode(int32_t *input_buffer_top, uint8_t *output_buffer_top,
                     int32_t *output_frame_size, lv5e_enc_context_t *ctx);
/* exposed for tests */
int32_t lv5e_enc_freq_shift(lv5e_segment_settings_t *segment, int32_t cutoff,
                            int32_t *data, int32_t *data_sft, uint8_t *jump,
                            int32_t *first_idx, uint32_t *logarithm_by_2_tbl_0);
void lv5e_freq_shift_apply_encode(lv5e_segment_settings_t *segment,
                                  int32_t *power_of_2_tbl, int32_t *data_sft,
                                  int32_t *data, int32_t size);
int32_t lv5e_enc_lossy_frame_length_program(int32_t enc_pixel_size_byte,
                                            lv5e_fdata_all_buffer_t *fdata_all_buffer);

/* ------------------------------------------------------------------ */
/* static tables                                                       */
/* ------------------------------------------------------------------ */

typedef struct {
  int32_t size;
  int32_t cutoff;
} lv5e_segment_cutoff_t;

extern const lv5e_segment_cutoff_t lv5e_segment_finish[18];
extern const uint32_t lv5e_init_frequency_table_01[3];
extern const uint32_t lv5e_init_frequency_table_02[3];
extern const int32_t lv5e_power_of_two_table[161];

/* ------------------------------------------------------------------ */
/* byte circular buffer for encoded frames                             */
/* ------------------------------------------------------------------ */

typedef struct {
  size_t idx;
  size_t odx;
  size_t s_len;
  size_t r_len;
  size_t max_len;
  size_t item_cnt;
  uint8_t cbuf[LV5E_MAX_QUEUE_FRAMES * LV5E_MAX_ENC_FRAME_SAMPLE * LV5E_MAX_CH];
} lv5e_cirbuf_t;

void lv5e_cirbuf_new(lv5e_cirbuf_t *c, size_t len);
void lv5e_cirbuf_reset(lv5e_cirbuf_t *c);
size_t lv5e_cirbuf_len(const lv5e_cirbuf_t *c);
size_t lv5e_cirbuf_empty_len(const lv5e_cirbuf_t *c);
void lv5e_cirbuf_get(lv5e_cirbuf_t *c, uint8_t *buf, size_t buf_len);
size_t lv5e_cirbuf_put(lv5e_cirbuf_t *c, const uint8_t *buf, size_t buf_len);

/* ------------------------------------------------------------------ */
/* encoder parameters + top-level context                              */
/* ------------------------------------------------------------------ */

typedef struct {
  uint32_t version;
  uint32_t sample_rate;
  uint32_t bits_per_sample;
  uint32_t bits_per_sample_ui;
  uint32_t last_bitrate;
  uint32_t quality_status;
  uint32_t actual_bitrate;
  uint32_t max_bitrate_inx;
  uint32_t min_bitrate_inx;
  uint32_t samples_per_frame;
  uint32_t frame_duration;
  uint32_t max_frame_per_packet;
  uint32_t frame_per_packet;
  uint32_t host_mtu_size;
  uint32_t target_mtu_size;
  uint32_t encode_interval;
  uint32_t encoded_frame_size;
  uint32_t max_frame_per_interval;
  bool update_frame_info;
  lv5e_enc_context_t lhdc_enc;
  lv5e_cirbuf_t input_cbuf;
  int32_t enc_in_buf[LV5E_MAX_ENC_FRAME_SAMPLE * LV5E_MAX_CH];
  int32_t enc_out_buf[LV5E_MAX_ENC_FRAME_SAMPLE * LV5E_MAX_CH];
  const uint32_t *bitrate_table; /* 15 entries */
} lv5e_parameters_t;

/* Top-level context behind the public opaque handle */
struct lhdcv5_enc {
  uint32_t enc_type;
  int32_t err;
  lv5e_parameters_t enc;
};

#endif /* LHDCV5_INT_H */
