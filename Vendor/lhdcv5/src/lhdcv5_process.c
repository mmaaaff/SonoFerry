/*
 * Core lossy encoding: quantization, symbol generation, rate control,
 * bitstream packing.
 * Copyright (C) 2025, The Android Open Source Project
 * SPDX-License-Identifier: Apache-2.0
 */
#include "lhdcv5_int.h"

/*
 * Computes a moving average for the input vector.
 * The averaging window extends one below and 2 above the index being
 * calculated for.
 */
static void moving_average(const int32_t *input, size_t input_len, int32_t *output) {
  int32_t total;
  size_t i;
  output[0] = input[0];
  total = input[0] + input[1] + input[2] + input[3];
  output[1] = lv5e_div_round(total, 4);
  i = 2;
  while (i < input_len - 2) {
    total += input[i + 2] - input[i - 2];
    output[i] = lv5e_div_round(total, 4);
    i += 1;
  }
  total -= input[i - 2];
  output[i] = lv5e_div3(total);
  i += 1;
  output[i] = input[i - 1];
}

static const int32_t JUMP_TABLE[64] = {
    6,    13,   19,   26,   32,   38,   45,   51,   58,   64,   77,   90,   102,
    115,  128,  141,  154,  166,  186,  205,  224,  243,  262,  282,  301,  326,
    352,  378,  403,  429,  461,  493,  525,  557,  595,  634,  672,  717,  762,
    813,  870,  934,  1005, 1082, 1165, 1254, 1350, 1453, 1562, 1677, 1798, 1926,
    2061, 2202, 2349, 2502, 2662, 2829, 3002, 3187, 3386, 3603, 3840, 4096};

static void lhdc_enc_symbol_generation_step_1(int32_t *idx, const uint32_t *queue1,
                                              size_t size, int32_t codeing_step_0,
                                              uint8_t *queue2) {
  size_t data2_idx = 0;
  size_t idx_max;
  size_t i;
  codeing_step_0 = ((size_t)codeing_step_0 > size) ? (int32_t)size : codeing_step_0;
  idx_max = size - (size_t)codeing_step_0;
  for (i = 0; i < size; i++) {
    if (queue1[i] > 1 && data2_idx <= idx_max) {
      data2_idx = i;
      queue2[i] = (1 << 2) - 1 - 1;
    } else {
      queue2[i] = (uint8_t)(queue1[i] & 1);
    }
  }
  *idx = (int32_t)data2_idx;
}

static int32_t lhdc_enc_symbol_generation_step_2(int32_t idx, const uint32_t *queue1,
                                                 size_t size, uint8_t *queue2,
                                                 int32_t lossy_symbol_size_top) {
  uint32_t tmp = 0;
  int32_t data2_idx = idx;
  size_t size2 = size;
  size_t i;
  for (i = 0; i < size; i++) {
    uint32_t elem = queue1[i];
    bool have_tmp;
    if ((int32_t)i > data2_idx) {
      tmp = elem >> 1;
      have_tmp = true;
    } else if (elem <= 1) {
      have_tmp = false;
    } else {
      tmp = elem - 2;
      have_tmp = true;
    }
    if (have_tmp) {
      int32_t stop = 0;
      if (tmp != 0) {
        for (;;) {
          if ((int32_t)size2 >= lossy_symbol_size_top - 3) {
            return -1;
          }
          if (tmp < (1 << 2)) {
            break;
          }
          stop += 1;
          queue2[size2] = (1 << 2) - 1 - 1;
          size2 += 1;
          queue2[size2] = (uint8_t)((tmp >> 1) & 1);
          size2 += 1;
          queue2[size2] = (uint8_t)(tmp & 1);
          size2 += 1;
          tmp >>= 2;
        }
        tmp = (stop != 0) ? tmp - 1 : tmp;
        if (size2 + (size_t)tmp >= (size_t)lossy_symbol_size_top) {
          return -1;
        }
        if (tmp != 0) {
          switch (tmp) {
            case 1:
              queue2[size2] = 1;
              size2 += 1;
              break;
            case 2:
              queue2[size2] = 1;
              size2 += 1;
              queue2[size2] = 1;
              size2 += 1;
              break;
            default:
              queue2[size2] = 1;
              size2 += 1;
              queue2[size2] = 1;
              size2 += 1;
              queue2[size2] = 1;
              size2 += 1;
              break;
          }
        }
      }
      if (size2 >= (size_t)lossy_symbol_size_top) {
        return -1;
      }
      if (tmp <= 2) {
        queue2[size2] = 0;
        size2 += 1;
      }
    }
  }
  return (int32_t)size2;
}

static int32_t init_bn(lv5e_fdata_all_buffer_t *enc_text) {
  int32_t v = enc_text->fdata_enc_buffer.level.fdata_q_quant_bit_num[1];
  if (enc_text->fdata_quant_rem_data_size == 0) {
    v = 0;
  } else if (enc_text->fdata_quant_rem_data_size_top < v) {
    v = enc_text->fdata_quant_rem_data_size_top;
  }
  return v;
}

static void coef_calc(lv5e_fdata_buffer_t *level, int32_t init_bn_v,
                      size_t enc_pixel_size_byte) {
  int32_t *bits_num = level->fdata_q_quant_bit_num;
  int32_t *coef7 = (int32_t *)level->fdata_q_quant_2_symbol; /* aliases the symbol buf */
  int32_t *coef3 = level->fdata_q_quant_rem;
  int32_t diff3 = 0;
  int32_t diff7 = 0;
  size_t i;
  coef3[0] = init_bn_v;
  coef7[0] = init_bn_v;
  bits_num[0] = init_bn_v;
  if (enc_pixel_size_byte < 200) {
    for (i = 1; i < (size_t)level->valid; i++) {
      int32_t diff_3_bits, diff_7_bits;
      coef3[i] = (coef3[i - 1] * 3 + bits_num[i] * 5) >> 3;
      diff_3_bits = coef3[i] - bits_num[i + 1];
      diff3 += diff_3_bits ^ (diff_3_bits >> 31);
      coef7[i] = (coef7[i - 1] * 7 + bits_num[i]) >> 3;
      diff_7_bits = coef7[i] - bits_num[i + 1];
      diff7 += diff_7_bits ^ (diff_7_bits >> 31);
    }
    level->symbol_flag = (diff7 <= diff3) ? 1 : 0;
  } else {
    for (i = 1; i < (size_t)level->valid; i++) {
      coef7[i] = (coef7[i - 1] * 7 + bits_num[i]) >> 3;
    }
    level->symbol_flag = 1;
  }
}

static int32_t lhdc_enc_symbol_generation(const uint32_t *queue1, size_t size,
                                          int32_t codeing_step_0, uint8_t *queue2,
                                          int32_t lossy_symbol_size_top) {
  int32_t data2_idx = 0;
  lhdc_enc_symbol_generation_step_1(&data2_idx, queue1, size, codeing_step_0, queue2);
  data2_idx = (data2_idx < (int32_t)size - codeing_step_0) ? (int32_t)size : data2_idx;
  return lhdc_enc_symbol_generation_step_2(data2_idx, queue1, size, queue2,
                                           lossy_symbol_size_top);
}

static int32_t lhdc_enc_symbol_calc(lv5e_fdata_all_buffer_t *enc_text) {
  const uint8_t *umem8 = (const uint8_t *)enc_text->fdata_enc_buffer.level.fdata_q_quant_bit_num;
  int32_t size1 = enc_text->fdata_enc_buffer.level.valid;
  int32_t size2 = enc_text->fdata_enc_buffer.level.fdata_q_size;
  int32_t total = lv5e_arith_esti(umem8, (size_t)size1, enc_text->init_fq_tbl_01, 3);
  total += lv5e_arith_esti(umem8 + size1, (size_t)(size2 - size1),
                           enc_text->init_fq_tbl_02, 3);
  total = lv5e_wmul(enc_text->esti_diff_value, total) >> 16;
  return total;
}

/* returns 0 on success, -1 on error (arith/bitout overflow) */
static int lhdc_enc_nbyte_out(lv5e_fdata_all_buffer_t *enc_text,
                              lv5e_arith_base_t *enc_arith_base, lv5e_bitout_t *bit_outputter) {
  const uint8_t *lossy_uc =
      (const uint8_t *)enc_text->fdata_enc_buffer.level.fdata_q_quant_bit_num;
  uint8_t *umem8 = (uint8_t *)enc_text->fdata_enc_buffer.level.fdata_q_quant_2_symbol;
  size_t umem8_len = (size_t)enc_text->pixel_num_top * 4;
  lv5e_arith_enc_t enc_arith;
  size_t size;
  size_t i;
  int32_t written;

  lv5e_arith_enc_new(&enc_arith, enc_arith_base, umem8, umem8_len);
  lv5e_arith_program(&enc_arith, enc_text->init_fq_tbl_01, 3,
                     enc_text->segment_setting.arith_init_0);
  for (i = 0; i < (size_t)enc_text->fdata_enc_buffer.level.valid; i++) {
    if (lv5e_arith_symbol_3(&enc_arith, lossy_uc[i]) != 0) {
      return -1;
    }
  }
  lv5e_arith_program(&enc_arith, enc_text->init_fq_tbl_02, 3,
                     enc_text->segment_setting.arith_init_1);
  size = (size_t)(enc_text->fdata_enc_buffer.level.fdata_q_size -
                  enc_text->fdata_enc_buffer.level.valid);
  for (i = 0; i < size; i++) {
    if (lv5e_arith_symbol_3(
            &enc_arith, lossy_uc[(size_t)enc_text->fdata_enc_buffer.level.valid + i]) != 0) {
      return -1;
    }
  }
  written = lv5e_arith_clear(&enc_arith, bit_outputter);
  if (written < 0) {
    return -1;
  }
  enc_text->fdata_enc_buffer.level.fdata_q_true_len = written << 3;
  return 0;
}

static int32_t lhdc_enc_nbyte_esti(lv5e_fdata_all_buffer_t *enc_text) {
  int32_t *bits_num = enc_text->fdata_enc_buffer.level.fdata_q_quant_bit_num;
  lv5e_fdata_buffer_t *level = &enc_text->fdata_enc_buffer.level;
  const uint32_t *real_data =
      (const uint32_t *)level->fdata_q_quant + (enc_text->pixel_num - level->valid);
  uint32_t total = 0;
  int32_t ibn;
  size_t i;

  for (i = 0; i < (size_t)level->valid; i++) {
    bits_num[i + 1] = (int32_t)lv5e_log_2(real_data[i]) << 7;
  }
  ibn = init_bn(enc_text);
  coef_calc(level, ibn, (size_t)enc_text->enc_pixel_size_byte);
  real_data = (const uint32_t *)level->fdata_q_quant + (enc_text->pixel_num - level->valid);

  if (level->symbol_flag == 1) {
    /* coef7 - doesn't alias rem, but does alias queue1 (the symbol buffer) */
    int32_t *coef = (int32_t *)level->fdata_q_quant_2_symbol;
    int32_t *rb = level->fdata_q_quant_rem;
    for (i = 0; i < (size_t)level->valid; i++) {
      int32_t reserved_bits = (coef[i] + ((1 << 7) >> 1)) >> 7;
      coef[i] = (int32_t)(real_data[i] >> reserved_bits);
      rb[i] = reserved_bits;
      total += (uint32_t)reserved_bits;
    }
  } else {
    /* coef3 - aliases rem, but doesn't alias queue1 */
    int32_t *coef = level->fdata_q_quant_rem;
    for (i = 0; i < (size_t)level->valid; i++) {
      int32_t reserved_bits = (coef[i] + ((1 << 7) >> 1)) >> 7;
      level->fdata_q_quant_2_symbol[i] = real_data[i] >> reserved_bits;
      coef[i] = reserved_bits;
      total += (uint32_t)reserved_bits;
    }
  }
  level->fdata_q_size = lhdc_enc_symbol_generation(
      level->fdata_q_quant_2_symbol, (size_t)level->valid,
      enc_text->segment_setting.codeing_step_0,
      (uint8_t *)level->fdata_q_quant_bit_num, enc_text->lossy_symbol_size_top);
  if (level->fdata_q_size < 0) {
    return enc_text->target_range + 1;
  }
  level->fdata_q_esti_len = lhdc_enc_symbol_calc(enc_text);
  total += (uint32_t)enc_text->fdata_enc_buffer.level.fdata_q_len;
  total += (uint32_t)enc_text->fdata_enc_buffer.level.fdata_q_esti_len;
  return (int32_t)total;
}

static int32_t index_calc(int32_t idx, int32_t max_idx, int32_t compare,
                          int32_t first_idx) {
  int32_t index = idx;
  while (index <= max_idx && JUMP_TABLE[index] < compare) {
    index += 1;
  }
  index = (index > first_idx) ? index - 1 : index;
  return index;
}

static void lhdc_enc_lossy_jump_adust_process(const int32_t *in_0, int32_t *out,
                                              int32_t size, uint8_t *bindata,
                                              int32_t *first_idx, int32_t max_idx) {
  int32_t compare = in_0[1];
  int32_t index;
  int32_t est_control = 1;
  int32_t estimate;
  size_t i;
  compare = (compare < 0) ? -compare : compare;
  index = *first_idx;
  index = index_calc(index, max_idx, compare, *first_idx);
  *first_idx = index;
  out[0] = in_0[0];
  estimate = out[0];
  for (i = 0; i < (size_t)size - 1; i++) {
    int32_t sign_step;
    compare = in_0[i + 1] - estimate;
    bindata[i] = (uint8_t)((compare < 0) ? 1 : 0);
    if (i != 0) {
      int32_t tmp = (int32_t)bindata[i] - (int32_t)bindata[i - 1];
      if (tmp == 0) {
        est_control += 1;
        index += est_control;
        index = (index >= 64) ? 64 - 1 : index;
      } else {
        index = (index * 3 + 2) >> 2;
        index = (index < 0) ? 0 : index;
        est_control = 1;
      }
    }
    sign_step = (bindata[i] != 0) ? -JUMP_TABLE[index] : JUMP_TABLE[index];
    estimate += sign_step;
    out[i + 1] = estimate;
  }
}

static const uint32_t LOG_2_TABLE[64] = {
    87720, 87720, 86696, 86256, 89768, 90080, 89328, 89492, 88744, 88600, 89056,
    88944, 88304, 88164, 88468, 88328, 83624, 83696, 83480, 83540, 83936, 83768,
    83824, 83120, 83184, 83004, 83044, 83372, 83348, 83416, 83208, 83320, 82600,
    82564, 82672, 82476, 82456, 82544, 82516, 82828, 82912, 82904, 82744, 82716,
    82800, 82768, 82096, 82064, 82160, 82140, 81980, 81944, 82020, 81984, 82348,
    82312, 82324, 82428, 82392, 82208, 82184, 82192, 82296, 82240};

int32_t lv5e_enc_freq_shift(lv5e_segment_settings_t *segment, int32_t cutoff,
                                   int32_t *data, int32_t *data_sft, uint8_t *jump,
                                   int32_t *first_idx, uint32_t *logarithm_by_2_tbl_0) {
  int32_t se[32];
  int32_t dirty_bottom = 0;
  size_t segment_num = segment->segment_num;
  size_t s;
  int32_t log_dirty_bottom;
  int32_t avg;
  uint32_t val;
  int32_t tmp;
  size_t i;

  for (s = 0; s < segment_num; s++) {
    int32_t acc = 0;
    size_t d;
    for (d = segment->segment_offset[s]; d < segment->segment_offset[s + 1]; d++) {
      acc = (int32_t)((int64_t)acc + (((int64_t)data[d] * (int64_t)data[d]) >> 31));
    }
    acc = (int32_t)(((int64_t)acc * (int64_t)segment->segment_scale[s]) >>
                    segment->segment_scale_jump);
    se[s] = acc;
    dirty_bottom += acc;
  }
  data_sft[segment_num - 2] =
      (int32_t)(((644245094LL * (int64_t)se[segment_num - 1]) >> 31) +
                ((858993459LL * (int64_t)se[segment_num - 2]) >> 31) +
                ((429496729LL * (int64_t)se[segment_num - 3]) >> 31) +
                ((214748364LL * (int64_t)se[segment_num - 4]) >> 31));
  data_sft[segment_num - 1] =
      (int32_t)(((1503238553LL * (int64_t)se[segment_num - 1]) >> 31) +
                ((429496729LL * (int64_t)se[segment_num - 2]) >> 31) +
                ((214748364LL * (int64_t)se[segment_num - 3]) >> 31));
  data_sft[0] = (int32_t)(((1503238553LL * (int64_t)se[0]) >> 31) +
                          ((429496729LL * (int64_t)se[1]) >> 31) +
                          ((214748364LL * (int64_t)se[2]) >> 31));
  data_sft[1] = (int32_t)(((644245094LL * (int64_t)se[0]) >> 31) +
                          ((858993459LL * (int64_t)se[1]) >> 31) +
                          ((429496729LL * (int64_t)se[2]) >> 31) +
                          ((214748364LL * (int64_t)se[3]) >> 31));
  for (i = 2; i < segment_num - 2; i++) {
    data_sft[i] =
        (int32_t)(((214748364LL * ((int64_t)se[i - 2] + (int64_t)se[i + 2])) >> 31) +
                  ((858993459LL * (int64_t)se[i]) >> 31) +
                  ((429496729LL * ((int64_t)se[i - 1] + (int64_t)se[i + 1])) >> 31));
  }
  dirty_bottom =
      (int32_t)(((int64_t)dirty_bottom * (int64_t)segment->segment_num_inv) >> 31);
  dirty_bottom = (int32_t)(((int64_t)dirty_bottom * 214748LL) >> 31);
  dirty_bottom = (dirty_bottom < 1) ? 1 : dirty_bottom;

  val = (uint32_t)dirty_bottom;
  if (val < 64) {
    tmp = (int32_t)logarithm_by_2_tbl_0[val];
  } else {
    tmp = lv5e_log_2(val);
    val >>= tmp - 6;
    tmp = (int32_t)(logarithm_by_2_tbl_0[val] + (uint32_t)((tmp - 1) << 8));
  }

  log_dirty_bottom = (tmp + 31 * (1 << 8)) >> 1;
  avg = 0;
  for (s = 0; s < segment_num; s++) {
    val = (uint32_t)data_sft[s];
    if (val < 64) {
      tmp = (int32_t)logarithm_by_2_tbl_0[val];
    } else {
      tmp = lv5e_log_2(val);
      val >>= tmp - 6;
      tmp = (int32_t)(logarithm_by_2_tbl_0[val] + (uint32_t)((tmp - 1) << 8));
    }
    se[s] = (data_sft[s] < dirty_bottom) ? log_dirty_bottom : ((tmp + 31 * (1 << 8)) >> 1);
    avg += se[s];
  }
  avg = (int32_t)(((int64_t)avg * (int64_t)segment->segment_num_inv) >> 31);
  data_sft[segment_num - 2] =
      (int32_t)(((644245094LL * (int64_t)se[segment_num - 1]) >> 31) +
                ((858993459LL * (int64_t)se[segment_num - 2]) >> 31) +
                ((429496729LL * (int64_t)se[segment_num - 3]) >> 31) +
                ((214748364LL * (int64_t)se[segment_num - 4]) >> 31));
  data_sft[segment_num - 1] =
      (int32_t)(((1503238553LL * (int64_t)se[segment_num - 1]) >> 31) +
                ((429496729LL * (int64_t)se[segment_num - 2]) >> 31) +
                ((214748364LL * (int64_t)se[segment_num - 3]) >> 31));
  data_sft[0] = (int32_t)(((1503238553LL * (int64_t)se[0]) >> 31) +
                          ((429496729LL * (int64_t)se[1]) >> 31) +
                          ((214748364LL * (int64_t)se[2]) >> 31));
  data_sft[1] = (int32_t)(((644245094LL * (int64_t)se[0]) >> 31) +
                          ((858993459LL * (int64_t)se[1]) >> 31) +
                          ((429496729LL * (int64_t)se[2]) >> 31) +
                          ((214748364LL * (int64_t)se[3]) >> 31));
  for (i = 2; i < segment_num - 2; i++) {
    data_sft[i] =
        (int32_t)(((214748364LL * ((int64_t)se[i - 2] + (int64_t)se[i + 2])) >> 31) +
                  ((858993459LL * (int64_t)se[i]) >> 31) +
                  ((429496729LL * ((int64_t)se[i - 1] + (int64_t)se[i + 1])) >> 31));
  }
  if (4250 > avg && 480 < cutoff) {
    memset(jump, 0, segment_num - 1);
    *first_idx = 8 + (1 << 4) - 2 + 1;
    return avg;
  }
  data_sft[0] = (int32_t)((((int64_t)data_sft[0] - (int64_t)avg) *
                           (int64_t)segment->segment_scale_level) >>
                          31);
  for (s = 1; s < segment_num; s++) {
    data_sft[s] = (int32_t)((((int64_t)data_sft[s] - (int64_t)avg) *
                             (int64_t)segment->segment_scale_level) >>
                            31);
    data_sft[s] -= data_sft[0];
  }
  data_sft[0] = 0;
  *first_idx = 8;
  lhdc_enc_lossy_jump_adust_process(data_sft, se, (int32_t)segment_num, jump, first_idx,
                                    8 + (1 << 4) - 2);
  for (i = 1; i < segment_num; i++) {
    se[0] += se[i];
  }
  se[0] = (int32_t)(((int64_t)(-se[0]) * (int64_t)segment->segment_num_inv) >> 31);
  for (i = 1; i < segment_num; i++) {
    se[i] += se[0];
  }
  moving_average(se, segment_num, data_sft);
  for (s = 0; s < segment_num; s++) {
    int32_t v = data_sft[s];
    if (v < -10 * (1 << 8)) {
      v = -10 * (1 << 8);
    } else if (v > 4 * (1 << 8)) {
      v = 4 * (1 << 8);
    }
    data_sft[s] = -v;
  }
  return avg;
}

void lv5e_freq_shift_apply_encode(lv5e_segment_settings_t *segment,
                                         int32_t *power_of_2_tbl, int32_t *data_sft,
                                         int32_t *data, int32_t size) {
  size_t s = 0;
  float power2;
  int32_t fixed_power2;
  int32_t index_top;
  int32_t index_bottom;
  int32_t swath = 0;
  while (s < segment->segment_num && swath < size) {
    int32_t j;
    int32_t *cf;
    if (data_sft[s] >= 0) {
      power2 = (float)power_of_2_tbl[data_sft[s] >> (8 - 4)] * 0.0000009536743f;
    } else {
      power2 = (float)power_of_2_tbl[((1 << 8) * 10 + 15 + data_sft[s]) >> (8 - 4)] *
               0.0000000009313226f;
    }
    fixed_power2 = (int32_t)(power2 * (float)(1LL << 26));
    index_top = ((int32_t)segment->segment_offset[s + 1] >= size)
                    ? size
                    : (int32_t)segment->segment_offset[s + 1];
    index_bottom = ((int32_t)segment->segment_offset[s] >= size)
                       ? size
                       : (int32_t)segment->segment_offset[s];
    cf = data + segment->segment_offset[s];
    swath = index_top - index_bottom;
    for (j = 0; j < swath; j++) {
      cf[j] = (int32_t)(((int64_t)cf[j] * (int64_t)fixed_power2) >> 26);
    }
    s += 1;
  }
}

static int32_t enc_lossy_check_parameter(int32_t ms, int32_t khz, int32_t resolution) {
  if (resolution != 16 && resolution != 24) {
    return -1;
  }
  switch (ms) {
    case 25:
    case 75:
    case 100:
      return -1;
    default:
      break;
  }
  switch (khz) {
    case 8000:
    case 16000:
    case 24000:
    case 32000:
      return -1;
    default:
      break;
  }
  return 0;
}

static int32_t lhdc_enc_lossy_start(lv5e_enc_context_t *ctx, int32_t ch_num,
                                    int32_t resolution, int32_t khz, int32_t ms,
                                    int32_t enc_pixel_size_byte) {
  lv5e_fdata_all_buffer_t *fdata_all_buffer = &ctx->ebuffer;
  if (khz > fdata_all_buffer->khz_top || ms > fdata_all_buffer->ms_top) {
    return -1;
  }
  if (enc_lossy_check_parameter(ms, khz, resolution) < 0) {
    return -1;
  }
  return lv5e_fdata_all_buffer_reset(fdata_all_buffer, ms, khz, resolution, ch_num,
                                     (size_t)enc_pixel_size_byte);
}

static void calc_header_data_size(int32_t *header_data_size, int32_t valid_num,
                                  int32_t segment_num, int32_t fdata_quant_rem_data_size) {
  *header_data_size = 1;
  *header_data_size += 1;
  *header_data_size += 9;
  *header_data_size += 4;
  *header_data_size += valid_num;
  *header_data_size += segment_num - 1;
  *header_data_size += fdata_quant_rem_data_size;
}

#define SEGMENT_RATE_480_HR 480
#define SEGMENT_RATE_480 481
#define SEGMENT_RATE_480_LB 482

static int32_t calc_segment_value(int32_t khz, int32_t ms, int32_t bit_rate,
                                  int32_t pixel_num) {
  int32_t sg_r;
  if ((khz == 44100 || khz == 48000) && (ms == 100 || ms == 50)) {
    if (bit_rate > 119999) {
      sg_r = SEGMENT_RATE_480_HR;
    } else if (bit_rate > 95999) {
      sg_r = SEGMENT_RATE_480;
    } else {
      sg_r = SEGMENT_RATE_480_LB;
    }
  } else if (khz == 96000 && ms == 50) {
    sg_r = 960;
  } else if (khz == 192000 && ms == 50) {
    sg_r = 1920;
  } else {
    sg_r = pixel_num;
  }
  return sg_r;
}

static void cale_offset_size(int32_t *offset_size, int32_t frm_byte) {
  *offset_size *= frm_byte;
  *offset_size = (*offset_size >= (1 << 9)) ? (1 << 9) - 1 : *offset_size;
}

static void calc_target_range(int32_t *target_range, int32_t *target_range_bottom,
                              int32_t enc_pixel_size_byte, int32_t header_data_size,
                              int32_t bottom) {
  *target_range = enc_pixel_size_byte * 8 - header_data_size;
  *target_range_bottom = *target_range * bottom / 100;
  *target_range_bottom = (*target_range - *target_range_bottom < 24)
                             ? *target_range - 24
                             : *target_range_bottom;
}

int32_t lv5e_enc_lossy_frame_length_program(int32_t enc_pixel_size_byte,
                                            lv5e_fdata_all_buffer_t *fdata_all_buffer) {
  int32_t khz = fdata_all_buffer->khz;
  int32_t ms = fdata_all_buffer->ms;
  int32_t enc_pixel_size_byte_bottom = 30 * fdata_all_buffer->ms / 100;
  int32_t enc_pixel_size_byte_top = 2000;
  int32_t frame_number;
  size_t index;
  int32_t bit_rate;
  int32_t bottom;

  if (enc_pixel_size_byte < enc_pixel_size_byte_bottom ||
      enc_pixel_size_byte > enc_pixel_size_byte_top) {
    return -1;
  }
  frame_number = enc_pixel_size_byte * 100 / fdata_all_buffer->ms;
  index = 0;
  while (frame_number > lv5e_segment_finish[index].size) {
    if (index == 17) {
      break;
    }
    index += 1;
  }
  fdata_all_buffer->segment_cutoff =
      lv5e_segment_finish[index].cutoff * fdata_all_buffer->ms / 100;
  if (fdata_all_buffer->segment_cutoff > fdata_all_buffer->pixel_num) {
    fdata_all_buffer->segment_cutoff = fdata_all_buffer->pixel_num;
  }
  lv5e_level_table_init(&fdata_all_buffer->level_table, enc_pixel_size_byte,
                        fdata_all_buffer->resolution, khz, ms);
  bit_rate = enc_pixel_size_byte * 8 * 10000 / fdata_all_buffer->ms;
  if (fdata_all_buffer->ms < 100) {
    bottom = 90;
  } else if (bit_rate > 119999) {
    bottom = 96;
  } else {
    bottom = 95;
  }
  if (!lv5e_segment_settings_init(
          &fdata_all_buffer->segment_setting,
          (size_t)calc_segment_value(khz, ms, bit_rate, fdata_all_buffer->pixel_num))) {
    return -1;
  }
  for (index = 0; index < 3; index++) {
    fdata_all_buffer->init_fq_tbl_01[index] =
        (lv5e_init_frequency_table_01[index] >> 2) ^ 21930u;
    fdata_all_buffer->init_fq_tbl_02[index] =
        (lv5e_init_frequency_table_02[index] >> 2) ^ 21930u;
  }
  for (index = 0; index < 161; index++) {
    fdata_all_buffer->power_of_2_tbl[index] =
        (int32_t)(((uint32_t)lv5e_power_of_two_table[index] - 85426866u) ^ 1437226410u);
  }
  for (index = 0; index < 64; index++) {
    fdata_all_buffer->logarithm_by_2_tbl[index] = (LOG_2_TABLE[index] >> 2) ^ 21930u;
  }
  fdata_all_buffer->fdata_quant_rem_data_size = (enc_pixel_size_byte < 160) ? 0 : 4;
  fdata_all_buffer->fdata_quant_rem_data_size_top =
      (enc_pixel_size_byte < 160) ? 0 : ((1 << 4) - 1) << 7;
  cale_offset_size(&fdata_all_buffer->fdata_ch_buffer[0].offset_size,
                   fdata_all_buffer->enc_pixel_size_byte / enc_pixel_size_byte);
  cale_offset_size(&fdata_all_buffer->fdata_ch_buffer[1].offset_size,
                   fdata_all_buffer->enc_pixel_size_byte / enc_pixel_size_byte);
  fdata_all_buffer->enc_pixel_size_byte = enc_pixel_size_byte;
  fdata_all_buffer->enc_pixel_size_bits = enc_pixel_size_byte << 3;
  calc_header_data_size(&fdata_all_buffer->header_data_size, fdata_all_buffer->valid_num,
                        (int32_t)fdata_all_buffer->segment_setting.segment_num,
                        fdata_all_buffer->fdata_quant_rem_data_size);
  calc_target_range(&fdata_all_buffer->target_range,
                    &fdata_all_buffer->target_range_bottom, enc_pixel_size_byte,
                    fdata_all_buffer->header_data_size, bottom);
  if (fdata_all_buffer->resolution == 16) {
    if (fdata_all_buffer->enc_pixel_size_byte <= 125) {
      fdata_all_buffer->esti_diff_value =
          69468 -
          ((69468 - 65864) * (fdata_all_buffer->enc_pixel_size_byte - 50) + 32) /
              (125 - 50);
    } else {
      fdata_all_buffer->esti_diff_value = 66192;
    }
  } else if (fdata_all_buffer->enc_pixel_size_byte <= 120) {
    fdata_all_buffer->esti_diff_value =
        68812 -
        ((68812 - 65536) * (fdata_all_buffer->enc_pixel_size_byte - 50) + 35) /
            (120 - 50);
  } else {
    fdata_all_buffer->esti_diff_value = 65536;
  }
  return 0;
}

static int32_t lhdc_enc_lossy_frame_size_program(lv5e_enc_context_t *ctx) {
  return ctx->ebuffer.pixel_num;
}

static void lhdc_enc_lossy_freq_process(lv5e_fdata_all_buffer_t *fdata_all_buffer,
                                        int32_t channel) {
  int32_t *data_in = (int32_t *)fdata_all_buffer->frequency_mem.frequency_buffers.fft_coef_in;
  int32_t *lossy_fdata_buf = fdata_all_buffer->fdata_enc_buffer.lossy_fdata_buf;
  int32_t pixel_num = fdata_all_buffer->pixel_num;
  int32_t pixel_num_top = 1 << 30;
  int32_t pixel_num_bottom = -(1 << 30);
  const int32_t *ecb_pcm = fdata_all_buffer->frequency_mem.frequency_buffers.freq_data +
                           fdata_all_buffer->pixel_ov_num;

  memcpy(data_in, ecb_pcm, (size_t)pixel_num * sizeof(int32_t));
  lv5e_enc_lossy_frequency_operation(&fdata_all_buffer->frequency_mem, channel,
                                     lossy_fdata_buf);
  fdata_all_buffer->fdata_enc_buffer.lossy_fdata_ave = lv5e_enc_freq_shift(
      &fdata_all_buffer->segment_setting, fdata_all_buffer->segment_cutoff,
      lossy_fdata_buf, fdata_all_buffer->fdata_enc_buffer.freqency_segment,
      fdata_all_buffer->fdata_enc_buffer.lossy_jump_adus_parameter,
      &fdata_all_buffer->fdata_enc_buffer.lossy_jump_adus_num,
      fdata_all_buffer->logarithm_by_2_tbl);
  if (fdata_all_buffer->fdata_enc_buffer.lossy_jump_adus_num != 8 + (1 << 4) - 2 + 1) {
    lv5e_freq_shift_apply_encode(&fdata_all_buffer->segment_setting,
                                 fdata_all_buffer->power_of_2_tbl,
                                 fdata_all_buffer->fdata_enc_buffer.freqency_segment,
                                 lossy_fdata_buf, pixel_num);
  }
  fdata_all_buffer->fdata_enc_buffer.jump_level_top = 0;
  if (fdata_all_buffer->resolution == 24) {
    int32_t index = 0;
    while (index < pixel_num) {
      int32_t lossy_fdata = lossy_fdata_buf[index];
      pixel_num_top = (lossy_fdata > pixel_num_top) ? lossy_fdata : pixel_num_top;
      pixel_num_bottom = (lossy_fdata < pixel_num_bottom) ? lossy_fdata : pixel_num_bottom;
      index += 1;
    }
    pixel_num_bottom = -pixel_num_bottom;
    pixel_num_top = (pixel_num_bottom > pixel_num_top) ? pixel_num_bottom : pixel_num_top;
    if (pixel_num_top > 0) {
      index = 0;
      for (;;) {
        float level = lv5e_level_table_level(&fdata_all_buffer->level_table, index);
        if ((float)pixel_num_top * level <= (float)(1 << 30)) {
          break;
        }
        index += 1;
      }
      fdata_all_buffer->fdata_enc_buffer.jump_level_top = index;
    }
  }
}

static int32_t lhdc_enc_lossy_freq_level(lv5e_fdata_all_buffer_t *fdata_all_buffer,
                                         float level) {
  const int32_t *in_0 = fdata_all_buffer->fdata_enc_buffer.lossy_fdata_buf;
  int32_t cutoff = fdata_all_buffer->segment_cutoff;
  int32_t *out = fdata_all_buffer->fdata_enc_buffer.level.fdata_q_quant;
  int32_t *fdata_q_len = &fdata_all_buffer->fdata_enc_buffer.level.fdata_q_len;
  int32_t index;
  int32_t level_ = (int32_t)(level * (float)(1 << 30));
  int32_t n_level_ = -level_;
  int64_t out05_multiply_2 = (int64_t)(2.0f * 0.5f / level);
  int64_t n_out05_multiply_2 = -out05_multiply_2;
  int32_t sernum = 0;
  int32_t *out_tmp = out + (fdata_all_buffer->pixel_num - cutoff);
  size_t i;

  for (i = 0; i < (size_t)cutoff; i++) {
    int64_t in_ = in_0[cutoff - 1 - (int32_t)i];
    int64_t in_multiply_2_0 = in_ << 1;
    if (in_multiply_2_0 >= out05_multiply_2) {
      out_tmp[i] = (int32_t)((in_ * (int64_t)level_ + (1LL << (30 - 1))) >> 30);
      sernum += 1;
    } else if (in_multiply_2_0 <= n_out05_multiply_2) {
      out_tmp[i] = (int32_t)((in_ * (int64_t)n_level_ + (1LL << (30 - 1))) >> 30);
      sernum += 1;
    } else {
      out_tmp[i] = 0;
    }
  }
  *fdata_q_len = sernum;
  index = fdata_all_buffer->pixel_num - cutoff;
  while (index < fdata_all_buffer->pixel_num && out[index] == 0) {
    index += 1;
  }
  if (index == fdata_all_buffer->pixel_num) {
    return 0;
  }
  return fdata_all_buffer->pixel_num - index + (index & 1);
}

static float fast_calc_step(float jump, int32_t per_pixel_number, int32_t pixel_number,
                            int32_t offset_size, int32_t per_offset_size) {
  float tmp = jump * 0.8f;
  int32_t sign_tmp1 = per_pixel_number - pixel_number;
  int32_t sign_tmp2 = offset_size - per_offset_size;
  return ((sign_tmp2 > 0) ? (float)(sign_tmp1 / sign_tmp2) * 0.2f
                          : (float)(-sign_tmp1 / -sign_tmp2) * 0.2f) +
         tmp;
}

static int32_t lhdc_enc_lossy_nbyte_estimation(lv5e_fdata_all_buffer_t *fdata_all_buffer,
                                               size_t channel) {
  lv5e_fdata_ch_buffer_t *fdata_ch_buffer = &fdata_all_buffer->fdata_ch_buffer[channel];
  int32_t target_range = fdata_all_buffer->target_range;
  int32_t target_range_bottom = fdata_all_buffer->target_range_bottom;
  float offset = fdata_ch_buffer->offset_step;
  int32_t offset_tbl_size_bottom = (1 << 9) - 1;
  int32_t offset_tbl_size_top = -1;
  int32_t offset_size = fdata_ch_buffer->offset_size;
  int32_t per_offset_size = offset_size;
  int32_t pixel_number = 0;

  if (offset_size < fdata_all_buffer->fdata_enc_buffer.jump_level_top) {
    offset_size = fdata_all_buffer->fdata_enc_buffer.jump_level_top;
    per_offset_size = offset_size;
  }
  for (;;) {
    float level = lv5e_level_table_level(&fdata_all_buffer->level_table, offset_size);
    int32_t tmp_out = lhdc_enc_lossy_freq_level(fdata_all_buffer, level);
    int32_t *ncz_in = &fdata_all_buffer->fdata_enc_buffer.level.valid;
    int32_t per_pixel_number;
    *ncz_in = tmp_out;
    if (*ncz_in < 4) {
      *ncz_in = 4;
    }
    per_pixel_number = pixel_number;
    pixel_number = lhdc_enc_nbyte_esti(fdata_all_buffer);
    if (pixel_number > target_range) {
      offset_tbl_size_top = offset_size;
      if (offset_tbl_size_top == offset_tbl_size_bottom - 1) {
        offset_size = offset_tbl_size_bottom;
        level = lv5e_level_table_level(&fdata_all_buffer->level_table, offset_size);
        tmp_out = lhdc_enc_lossy_freq_level(fdata_all_buffer, level);
        ncz_in = &fdata_all_buffer->fdata_enc_buffer.level.valid;
        *ncz_in = tmp_out;
        if (*ncz_in < 4) {
          *ncz_in = 4;
        }
        pixel_number = lhdc_enc_nbyte_esti(fdata_all_buffer);
        break;
      }
    } else {
      if (pixel_number >= target_range_bottom) {
        break;
      }
      if (offset_size <= fdata_all_buffer->fdata_enc_buffer.jump_level_top) {
        break;
      }
      offset_tbl_size_bottom = offset_size;
      if (offset_size > fdata_all_buffer->level_table.start + 1) {
        if (offset_tbl_size_bottom == offset_tbl_size_top + 1) {
          break;
        }
      } else {
        offset_size -= 1;
        continue;
      }
    }
    if (offset_size != per_offset_size) {
      offset = fast_calc_step(offset, per_pixel_number, pixel_number, offset_size,
                              per_offset_size);
    }
    per_offset_size = offset_size;
    offset_size += (int32_t)((float)(pixel_number - target_range) / offset);
    if (offset_size == per_offset_size) {
      if (pixel_number < target_range) {
        offset_size -= 1;
      } else {
        offset_size += 1;
      }
    }
    offset_size = (offset_size <= fdata_all_buffer->level_table.start)
                      ? fdata_all_buffer->level_table.start + 1
                      : offset_size;
    if (offset_size > offset_tbl_size_bottom) {
      offset_size = offset_tbl_size_bottom - 1;
    } else if (offset_size <= offset_tbl_size_top) {
      offset_size = offset_tbl_size_top + 1;
    }
  }
  fdata_ch_buffer = &fdata_all_buffer->fdata_ch_buffer[channel];
  fdata_ch_buffer->offset_size = offset_size;
  fdata_ch_buffer->offset_step = offset;
  return pixel_number;
}

/* returns 0 on success, -1 on bit output overflow */
static int bit_write_uint(lv5e_bitout_t *nbyte_program,
                          lv5e_fdata_enc_buffer_t *fdata_enc_buffer, int32_t data_offset,
                          int32_t segment_num, int32_t valid_num,
                          int32_t fdata_quant_rem_data_size) {
  lv5e_fdata_buffer_t *fdata_buffer = &fdata_enc_buffer->level;
  if (lv5e_bitout_write_bits(nbyte_program, 0, 1) != 0) return -1;
  if (lv5e_bitout_write_bits(nbyte_program, (uint32_t)data_offset, 9) != 0) return -1;
  if (lv5e_bitout_write_bits(nbyte_program,
                             (uint32_t)fdata_enc_buffer->lossy_jump_adus_num - 8, 4) != 0)
    return -1;
  if (segment_num - 1 != 0) {
    int32_t index = 0;
    while (index < segment_num - 1) {
      if (lv5e_bitout_write_bits(nbyte_program,
                                 fdata_enc_buffer->lossy_jump_adus_parameter[index], 1) != 0)
        return -1;
      index += 1;
    }
  }
  if (lv5e_bitout_write_bits(nbyte_program, (uint32_t)((fdata_buffer->valid >> 1) - 1),
                             (uint32_t)valid_num) != 0)
    return -1;
  if (lv5e_bitout_write_bits(nbyte_program, (uint32_t)fdata_buffer->symbol_flag, 1) != 0)
    return -1;
  if (lv5e_bitout_write_bits(nbyte_program, (uint32_t)fdata_buffer->fdata_q_quant_rem[0],
                             (uint32_t)fdata_quant_rem_data_size) != 0)
    return -1;
  return 0;
}

/* returns enc_pixel_size_bits on success, negative on error */
static int32_t lhdc_enc_lossy_nbyte_out(lv5e_fdata_all_buffer_t *fdata_all_buffer,
                                        lv5e_arith_base_t *enc_arith,
                                        lv5e_bitout_t *nbyte_program, int32_t channel) {
  lv5e_fdata_ch_buffer_t *fdata_ch_buffer = &fdata_all_buffer->fdata_ch_buffer[channel];
  lv5e_fdata_enc_buffer_t *fdata_enc_buffer = &fdata_all_buffer->fdata_enc_buffer;
  lv5e_fdata_buffer_t *fdata_buffer = &fdata_enc_buffer->level;
  int32_t nbyte;
  uint32_t word = 0;
  uint32_t bit_len = 32;
  int32_t non_zero_counter;
  int32_t index;
  int32_t read_byte_number;
  const int32_t *read_data;
  int32_t level, n_level;
  size_t i;

  if (bit_write_uint(nbyte_program, fdata_enc_buffer, fdata_ch_buffer->offset_size,
                     (int32_t)fdata_all_buffer->segment_setting.segment_num,
                     fdata_all_buffer->valid_num,
                     fdata_all_buffer->fdata_quant_rem_data_size) != 0) {
    return -2;
  }
  if (lhdc_enc_nbyte_out(fdata_all_buffer, enc_arith, nbyte_program) != 0) {
    return -2;
  }

  nbyte = fdata_buffer->fdata_q_true_len;
  non_zero_counter = fdata_buffer->valid;
  index = 0;
  read_byte_number = index;
  read_data = fdata_buffer->fdata_q_quant + (fdata_all_buffer->pixel_num - fdata_buffer->valid);
  for (i = 0; i < (size_t)non_zero_counter; i++) {
    int32_t read_data_byte = fdata_buffer->fdata_q_quant_rem[i];
    int32_t rd = read_data[i];
    if (bit_len < (uint32_t)read_data_byte + 1) {
      if (lv5e_bitout_write_bits(nbyte_program, word, 32 - bit_len) != 0) {
        return -2;
      }
      bit_len = 32;
    }
    if (read_data_byte != 0) {
      word = (word << read_data_byte) |
             ((uint32_t)rd & (0xffffffffu >> (32 - read_data_byte)));
      bit_len -= (uint32_t)read_data_byte;
      read_byte_number += read_data_byte;
    }
    if (rd != 0) {
      bit_len -= 1;
      word <<= 1;
      if (fdata_enc_buffer->lossy_fdata_buf[(size_t)non_zero_counter - 1 - i] < 0) {
        word |= 1;
      }
    }
  }
  if (lv5e_bitout_write_bits(nbyte_program, word, 32u - bit_len) != 0) {
    return -2;
  }
  read_byte_number += fdata_buffer->fdata_q_len;
  if (read_byte_number < 24) {
    if (lv5e_bitout_write_bits(nbyte_program, 0, (uint32_t)(24 - read_byte_number)) != 0) {
      return -2;
    }
    read_byte_number = 24;
  }
  nbyte += read_byte_number;
  if (nbyte > fdata_all_buffer->target_range) {
    return -2; /* TargetRange error */
  }
  level = (int32_t)(lv5e_level_table_level(&fdata_all_buffer->level_table,
                                           fdata_ch_buffer->offset_size) *
                    (float)(1 << 30));
  n_level = -level;
  index = fdata_all_buffer->pixel_num - 1;
  while (nbyte < fdata_all_buffer->target_range &&
         index >= fdata_all_buffer->pixel_num - fdata_buffer->valid) {
    if (fdata_buffer->fdata_q_quant[index] != 0) {
      int32_t lossy_fdata =
          fdata_enc_buffer->lossy_fdata_buf[fdata_all_buffer->pixel_num - 1 - index];
      int32_t read_data_count =
          (lossy_fdata >= 0)
              ? (int32_t)((int64_t)lossy_fdata * (int64_t)level) >> 30
              : (int32_t)((int64_t)lossy_fdata * (int64_t)n_level) >> 30;
      if (lv5e_bitout_write_bits(
              nbyte_program, (uint32_t)(fdata_buffer->fdata_q_quant[index] - read_data_count),
              1) != 0) {
        return -2;
      }
      nbyte += 1;
    }
    index -= 1;
  }
  nbyte += fdata_all_buffer->header_data_size;
  while (nbyte + 8 < fdata_all_buffer->enc_pixel_size_bits) {
    if (lv5e_bitout_write_bits(nbyte_program, 0, 8) != 0) {
      return -2;
    }
    nbyte += 8;
  }
  if (lv5e_bitout_zero_pad(nbyte_program) != 0) {
    return -2;
  }
  return fdata_all_buffer->enc_pixel_size_bits;
}

static void lhdc_enc_top(const int32_t *data_in, int32_t *data_l_out_size,
                         int32_t *data_r_out_size, lv5e_enc_context_t *ctx) {
  lv5e_fdata_all_buffer_t *fdata_all_buffer = &ctx->ebuffer;
  int32_t channel = 0;
  uint32_t *outs[2];
  int32_t *sizes[2];

  outs[0] = ctx->encoded_data_ch0;
  outs[1] = ctx->encoded_data_ch1;
  sizes[0] = data_l_out_size;
  sizes[1] = data_r_out_size;

  while (channel < fdata_all_buffer->ch_num) {
    uint32_t *data_l_out = outs[channel];
    int32_t *data_l_out_size_p = sizes[channel];
    int32_t *ori_input_pcm = fdata_all_buffer->frequency_mem.frequency_buffers.freq_data +
                             fdata_all_buffer->pixel_ov_num;
    int32_t pixel_num = fdata_all_buffer->pixel_num;
    lv5e_bitout_t bo;
    int32_t cleared;

    memcpy(ori_input_pcm, data_in + (size_t)(pixel_num * channel),
           (size_t)pixel_num * sizeof(int32_t));
    fdata_all_buffer->frequency_mem.frequency_process_ch_num.offset =
        (size_t)(fdata_all_buffer->freqency_ov_top * channel);
    lhdc_enc_lossy_freq_process(fdata_all_buffer, channel);
    lhdc_enc_lossy_nbyte_estimation(fdata_all_buffer, (size_t)channel);

    for (;;) {
      int32_t density_size_enc;
      lv5e_bitout_new(&bo, data_l_out, 171);
      density_size_enc =
          lhdc_enc_lossy_nbyte_out(fdata_all_buffer, &ctx->enc_arith_s, &bo, channel);
      if (density_size_enc > 0) {
        break;
      }
      {
        lv5e_fdata_buffer_t *fdata_buffer = &fdata_all_buffer->fdata_enc_buffer.level;
        int32_t offset = fdata_all_buffer->pixel_num - fdata_buffer->valid;
        const int32_t *data = fdata_buffer->fdata_q_quant + offset;
        int32_t *read_data_byte = fdata_buffer->fdata_q_quant_rem;
        int32_t bit_len = 0;
        density_size_enc = fdata_buffer->fdata_q_true_len - fdata_buffer->fdata_q_esti_len;
        for (;;) {
          if (data[0] != 0 && data[1] != 0) {
            fdata_buffer->fdata_q_len -= 2;
            density_size_enc -= 2;
            bit_len += 40;
          } else if (data[0] == 0 && data[1] == 0) {
            bit_len += 8;
          } else {
            fdata_buffer->fdata_q_len -= 1;
            density_size_enc -= 1;
            bit_len += 20;
            bit_len += 4;
          }
          density_size_enc -= read_data_byte[0] + read_data_byte[1];
          fdata_buffer->valid -= 2;
          data += 2;
          read_data_byte += 2;
          if (density_size_enc <= (bit_len >> 4)) {
            break;
          }
        }
        lhdc_enc_nbyte_esti(fdata_all_buffer);
      }
    }

    cleared = lv5e_bitout_clear(&bo);
    *data_l_out_size_p = (cleared >= 0) ? cleared : 0;
    channel += 1;
  }
  fdata_all_buffer->frame_count += 1;
}

static int32_t lhdc_enc_lossy_nbyte_num_read(int32_t channel, int32_t khz, int32_t ms,
                                             int32_t bitrate) {
  int32_t frame_len = bitrate * ms / (8 * 1000 * 10 * channel);
  if (khz == 44100) {
    frame_len = bitrate * ms / (735 * 100 * channel);
  }
  return frame_len;
}

int lv5e_enc_init(int32_t channel, int32_t resolution, int32_t khz, int32_t ms,
                  int32_t bitrate, lv5e_enc_context_t *ctx) {
  int32_t frame_len;
  if (channel < 1 || channel > 8 || (resolution != 16 && resolution != 24) ||
      (khz != 8000 && khz != 16000 && khz != 24000 && khz != 32000 && khz != 44100 &&
       khz != 48000 && khz != 96000 && khz != 192000) ||
      ms != 50 || bitrate < 0 || bitrate > 1000000) {
    return -1;
  }
  frame_len = lhdc_enc_lossy_nbyte_num_read(channel, khz, ms, bitrate);
  ctx->hdr_s.enc_frm_len_provided = frame_len;
  if (lhdc_enc_lossy_start(ctx, channel, resolution, khz, ms, frame_len) < 0) {
    return -1;
  }
  return 0;
}

void lv5e_enc_get_samples_per_frame(int32_t *s_fps, lv5e_enc_context_t *ctx) {
  *s_fps = lhdc_enc_lossy_frame_size_program(ctx);
}

int lv5e_enc_set_bitrate(int32_t bitrate, lv5e_enc_context_t *ctx) {
  lv5e_fdata_all_buffer_t *fdata_all_buffer;
  int32_t channel, khz, ms, frame_len;
  lv5e_header_t *header;
  if (bitrate < 0 || bitrate > 1000000) {
    return -1;
  }
  fdata_all_buffer = &ctx->ebuffer;
  channel = fdata_all_buffer->ch_num;
  khz = fdata_all_buffer->khz;
  ms = fdata_all_buffer->ms;
  header = &ctx->hdr_s;
  frame_len = lhdc_enc_lossy_nbyte_num_read(channel, khz, ms, bitrate);
  header->enc_frm_len_provided = frame_len;
  header->enc_frm_len_need_update = 1;
  if (lv5e_enc_lossy_frame_length_program(frame_len, &ctx->ebuffer) < 0) {
    return -1;
  }
  return 0;
}

static const uint8_t XOR_MASK[8] = {0xff, 0xe7, 0x7a, 0xb3, 0xda, 0xe5, 0xcd, 0x73};
static const uint8_t SCRAMBLE_ORDER[2][8] = {{4, 0, 1, 5, 7, 3, 2, 6},
                                             {6, 3, 7, 0, 2, 1, 4, 5}};

static void encoded_data_encrypt(uint32_t *encoded_data) {
  uint8_t *byte = (uint8_t *)encoded_data;
  uint8_t tmp_byte[8];
  uint8_t scramble_index = byte[8] & 0x1;
  int32_t index;
  for (index = 0; index < 8; index++) {
    tmp_byte[index] = byte[index] ^ XOR_MASK[index];
  }
  for (index = 0; index < 8; index++) {
    byte[index] = tmp_byte[SCRAMBLE_ORDER[scramble_index][index]];
  }
}

void lv5e_enc_encode(int32_t *input_buffer_top, uint8_t *output_buffer_top,
                     int32_t *output_frame_size, lv5e_enc_context_t *ctx) {
  int32_t input_buffer_size_ch0 = 0;
  int32_t input_buffer_size_ch1 = 1;
  int32_t density_size_workable = 0;
  lv5e_fdata_all_buffer_t *fdata_all_buffer = &ctx->ebuffer;
  lv5e_header_t *header = &ctx->hdr_s;
  int32_t header_size;
  size_t copy_len;

  if (fdata_all_buffer->frame_cnt < 960) {
    fdata_all_buffer->frame_cnt += 1;
  }
  header_size = lv5e_enc_process_header(header, fdata_all_buffer->ch_num,
                                        &density_size_workable, output_buffer_top);
  output_buffer_top += header_size;
  if (header->enc_frm_len_need_update != 0) {
    lv5e_enc_lossy_frame_length_program(density_size_workable, fdata_all_buffer);
    header->enc_frm_len_need_update = 0;
  }
  lhdc_enc_top(input_buffer_top, &input_buffer_size_ch0, &input_buffer_size_ch1, ctx);

  encoded_data_encrypt(ctx->encoded_data_ch0);
  if (fdata_all_buffer->ch_num >= 2) {
    encoded_data_encrypt(ctx->encoded_data_ch1);
  }
  copy_len = (size_t)fdata_all_buffer->enc_pixel_size_byte;
  memcpy(output_buffer_top, ctx->encoded_data_ch0, copy_len);
  if (fdata_all_buffer->ch_num >= 2) {
    memcpy(output_buffer_top + copy_len, ctx->encoded_data_ch1, copy_len);
  }
  *output_frame_size =
      header_size + fdata_all_buffer->ch_num * fdata_all_buffer->enc_pixel_size_byte;
}
