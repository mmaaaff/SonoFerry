/* Encoder regression harness: encodes deterministic PCM and dumps every
 * (written_bytes, written_frames, payload) record for byte-wise comparison. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lhdcv5_enc.h"

int main(int argc, char **argv) {
  /* usage: ref_encode_c <sr> <bps> <bitrate_inx> <frames> <out_file> [switch_frame switch_inx] */
  uint32_t sr, bps, inx, frames;
  const char *out_path;
  int have_switch = 0;
  uint32_t sw_f = 0, sw_inx = 0;
  lhdcv5_enc_t *ctx;
  uint32_t spf = 0;
  size_t bytes_per_frame;
  uint32_t lcg = 0x12345678u;
  uint8_t *pcm;
  uint8_t out[16384];
  FILE *file;
  uint32_t f;
  int32_t ret;

  if (argc < 6) {
    fprintf(stderr, "usage: %s <sr> <bps> <bitrate_inx> <frames> <out> [swf swinx]\n",
            argv[0]);
    return 2;
  }
  sr = (uint32_t)strtoul(argv[1], NULL, 10);
  bps = (uint32_t)strtoul(argv[2], NULL, 10);
  inx = (uint32_t)strtoul(argv[3], NULL, 10);
  frames = (uint32_t)strtoul(argv[4], NULL, 10);
  out_path = argv[5];
  if (argc > 7) {
    have_switch = 1;
    sw_f = (uint32_t)strtoul(argv[6], NULL, 10);
    sw_inx = (uint32_t)strtoul(argv[7], NULL, 10);
  }

  ctx = lhdcv5_enc_new(LHDC_VERSION_1);
  if (ctx == NULL) {
    fprintf(stderr, "handle failed\n");
    return 1;
  }
  ret = lhdcv5_enc_init_encoder(ctx, sr, bps, inx, 660, 20);
  if (ret != LHDC_FRET_SUCCESS) {
    fprintf(stderr, "init failed: %d\n", ret);
    return 1;
  }
  ret = lhdcv5_enc_get_block_size(ctx, &spf);
  if (ret != LHDC_FRET_SUCCESS) {
    fprintf(stderr, "block size failed: %d\n", ret);
    return 1;
  }
  bytes_per_frame = (size_t)spf * 2 * bps / 8;
  pcm = (uint8_t *)malloc(bytes_per_frame);

  file = fopen(out_path, "wb");
  if (file == NULL) {
    fprintf(stderr, "cannot open %s\n", out_path);
    return 1;
  }

  for (f = 0; f < frames; f++) {
    uint32_t written = 0, frames_out = 0;
    size_t i;
    if (have_switch && f == sw_f) {
      ret = lhdcv5_enc_set_bitrate_index(ctx, sw_inx, true);
      if (ret != LHDC_FRET_SUCCESS) {
        fprintf(stderr, "set bitrate failed: %d\n", ret);
        return 1;
      }
    }
    for (i = 0; i < bytes_per_frame; i++) {
      lcg = lcg * 1664525u + 1013904223u;
      pcm[i] = (uint8_t)(lcg >> 24);
    }
    ret = lhdcv5_enc_encode(ctx, pcm, bytes_per_frame, out, sizeof(out), &written,
                            &frames_out);
    if (ret != LHDC_FRET_SUCCESS) {
      fprintf(stderr, "encode failed at frame %u: %d\n", f, ret);
      return 1;
    }
    fwrite(&written, 4, 1, file);
    fwrite(&frames_out, 4, 1, file);
    fwrite(out, 1, written, file);
  }
  fclose(file);
  free(pcm);
  lhdcv5_enc_free(ctx);
  printf("ok %s\n", out_path);
  return 0;
}
