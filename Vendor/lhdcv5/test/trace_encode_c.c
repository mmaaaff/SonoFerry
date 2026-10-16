/* Internal-state tracing harness: prints per-frame hashes of the encoder's
 * working buffers, useful for pinpointing where two builds diverge. */
#include <stdio.h>
#include <stdlib.h>

#include "lhdcv5_int.h"

static uint64_t fnv(const uint8_t *data, size_t len) {
  uint64_t h = 0xcbf29ce484222325ULL;
  size_t i;
  for (i = 0; i < len; i++) {
    h ^= data[i];
    h *= 0x100000001b3ULL;
  }
  return h;
}

static lv5e_enc_context_t g_ctx;

int main(int argc, char **argv) {
  int32_t khz = atoi(argv[1]);
  int32_t res = atoi(argv[2]);
  int32_t bitrate = atoi(argv[3]);
  int32_t frames = atoi(argv[4]);
  size_t pixel_num;
  uint32_t lcg = 0x12345678u;
  int32_t *input;
  uint8_t out[8192];
  int32_t f;
  (void)argc;

  if (lv5e_enc_context_new(&g_ctx, 2, 192000, 50, 0) != 0) {
    fprintf(stderr, "ctx failed\n");
    return 1;
  }
  lv5e_enc_context_set_version(&g_ctx, 1);
  if (lv5e_enc_init(2, res, khz, 50, bitrate, &g_ctx) != 0) {
    fprintf(stderr, "init failed\n");
    return 1;
  }
  pixel_num = (size_t)g_ctx.ebuffer.pixel_num;
  input = (int32_t *)malloc(pixel_num * 2 * sizeof(int32_t));

  for (f = 0; f < frames; f++) {
    size_t i;
    int32_t out_size = 0;
    const lv5e_fdata_all_buffer_t *eb;
    const lv5e_fdata_buffer_t *lv;
    uint32_t step0, step1;
    for (i = 0; i < pixel_num * 2; i++) {
      lcg = lcg * 1664525u + 1013904223u;
      input[i] = ((int32_t)(lcg >> 8) << 8) >> 8;
    }
    lv5e_enc_encode(input, out, &out_size, &g_ctx);
    eb = &g_ctx.ebuffer;
    lv = &eb->fdata_enc_buffer.level;
    memcpy(&step0, &eb->fdata_ch_buffer[0].offset_step, 4);
    memcpy(&step1, &eb->fdata_ch_buffer[1].offset_step, 4);
    printf(
        "f=%d size=%d hash=%016llx lossy=%016llx quant=%016llx rem=%016llx seg=%016llx "
        "os0=%d step0=%08x os1=%d step1=%08x valid=%d\n",
        f, out_size, (unsigned long long)fnv(out, (size_t)out_size),
        (unsigned long long)fnv((const uint8_t *)eb->fdata_enc_buffer.lossy_fdata_buf,
                                pixel_num * 4),
        (unsigned long long)fnv((const uint8_t *)lv->fdata_q_quant, pixel_num * 4),
        (unsigned long long)fnv((const uint8_t *)lv->fdata_q_quant_rem, pixel_num * 4),
        (unsigned long long)fnv((const uint8_t *)eb->fdata_enc_buffer.freqency_segment,
                                sizeof(eb->fdata_enc_buffer.freqency_segment)),
        eb->fdata_ch_buffer[0].offset_size, step0, eb->fdata_ch_buffer[1].offset_size,
        step1, lv->valid);
  }
  free(input);
  return 0;
}
