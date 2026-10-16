# LHDC V5 Encoder — portable C port

A self-contained **C99 port of the LHDC V5 (lossy) Bluetooth audio encoder**, translated
from the Rust implementation that ships in AOSP (`system/audio codecs`, Apache-2.0), as
mirrored in [sprlightning/liblhdc-collections](https://github.com/sprlightning/liblhdc-collections/tree/main/lhdcv5).

**Verified bit-exact against the original Rust encoder**: identical output streams over
hundreds of frames for every supported sample rate (44.1/48/96/192 kHz), both input
formats (S16/S24), multiple bitrate indexes, and mid-stream bitrate switches
(see *Conformance testing* below).

- No OS dependencies, no dynamic allocation required — runs on ESP32, ARM Cortex-M,
  RISC-V, or any little-endian 32/64-bit target with a C99 compiler.
- Only `libm` (`cos`, `sin`, `floor`) is used, and only during `init`, not per-frame.
- Public API mirrors the original `lhdcv5_enc_ffi_*` / `lhdcv5BT_*` surface.

> LHDC is a codec by Savitech/HWA. This port is for interoperability, research and
> personal projects; check codec licensing/certification requirements before shipping
> a commercial product that advertises LHDC support.

## Layout

```
include/lhdcv5_enc.h   public API (the only header you include)
src/                   library internals (one .c per module of the Rust original)
test/ref_encode_c.c    conformance harness (mirrors the Rust ref_encode harness)
examples/encode_stdin.c raw PCM -> LHDC command-line example
CMakeLists.txt         plain CMake library + ESP-IDF component (auto-detected)
library.json           PlatformIO manifest
```

## Quick start

```c
#include "lhdcv5_enc.h"

lhdcv5_enc_t *enc = lhdcv5_enc_new(LHDC_VERSION_1);          // or static: see below
lhdcv5_enc_init_encoder(enc,
    48000,                  // 44100 / 48000 / 96000 / 192000
    16,                     // 16 (s16le) or 24 (packed s24le, 3 bytes/sample)
    LHDC_QUALITY_LOW,       // bitrate index: 0..12 or LHDC_QUALITY_AUTO (~400 kbps here)
    LHDC_MTU_2MBPS,         // link MTU in bytes
    LHDC_ENC_INTERVAL_20MS);

uint32_t block;                                 // samples per frame per channel
lhdcv5_enc_get_block_size(enc, &block);         // 240 @44.1/48k, 480 @96k, 960 @192k

// feed exactly one 5 ms frame of interleaved stereo PCM per call:
size_t pcm_bytes = block * 2 * bits / 8;
uint8_t out[4096];
uint32_t written, frames;
lhdcv5_enc_encode(enc, pcm, pcm_bytes, out, sizeof(out), &written, &frames);
// `written` is 0 on most calls; a complete packet (several frames) every Nth call.
```

Encoded packets are what you'd place into A2DP media payloads (the same framing the
original `liblhdcv5.so` produced for the Android Bluetooth stack).

### Static allocation (no malloc)

```c
static uint64_t enc_mem[LHDCV5-context-size / 8];   // size via lhdcv5_enc_context_size()
lhdcv5_enc_t *enc = lhdcv5_enc_setup_mem(enc_mem, LHDC_VERSION_1);
```

Compile with `-DLHDCV5_NO_MALLOC` to strip `lhdcv5_enc_new`/`lhdcv5_enc_free` entirely.

### RAM footprint

The encoder context dominates RAM usage. Cap the supported sample rate at compile time
to shrink it:

| `LHDCV5_MAX_SAMPLE_RATE` | context size | supports            |
|--------------------------|--------------|---------------------|
| `192000` (default)       | ~117 KB      | all rates           |
| `96000`                  | ~73 KB       | up to 96 kHz        |
| `48000`                  | ~51 KB       | 44.1 & 48 kHz       |

The capped builds remain bit-exact for the rates they support; higher rates are
rejected at `init` with an error.

On ESP32, 48 kHz / 16-bit / 400 kbps is the practical sweet spot
(`-DLHDCV5_MAX_SAMPLE_RATE=48000`, ~51 KB of internal RAM).

## Building

**Plain CMake**

```sh
cmake -B build -DLHDCV5_BUILD_EXAMPLES=ON
cmake --build build
```

**ESP-IDF** — copy/submodule this directory into `components/lhdcv5_enc/`; the
`CMakeLists.txt` registers itself as a component automatically. Add
`lhdcv5_enc` to your app's `PRIV_REQUIRES` and include `lhdcv5_enc.h`.

**Arduino / PlatformIO** — PlatformIO picks up `library.json` as-is. For the plain
Arduino IDE, copy `src/*` and `include/lhdcv5_enc.h` into one library `src/` folder.

**Anything else** — compile the 12 files in `src/` with your toolchain and add
`include/` to the include path. C99, little-endian, no other requirements.

## Bitrate control

| index | `LHDC_QUALITY_*` | 44.1 kHz | 48/96/192 kHz |
|-------|------------------|----------|----------------|
| 0     | LOW0             | 64       | 64  kbps       |
| 1     | LOW1             | 160      | 160            |
| 2     | LOW2             | 192      | 192            |
| 3     | LOW3             | 240      | 256            |
| 4     | LOW4             | 320      | 320            |
| 5     | LOW              | 400      | 400            |
| 6     | MID              | 480      | 500            |
| 7     | HIGH             | 900      | 900            |
| 8     | HIGH1            | 1000     | 1000           |
| 13    | AUTO             | → starts at LOW (400)   |

`lhdcv5_enc_set_bitrate_index()` switches bitrate seamlessly mid-stream (applied once
the internal frame queue drains). Indexes 9–12 (1100–1400 kbps) are accepted by the
API but the core encoder rejects target bitrates above 1 Mbps at init/switch time —
same behaviour as the Rust original. Adaptive-bitrate policy (reacting to the A2DP
queue depth) lives a layer above this API; see `AOSP/liblhdcv5/src/lhdcv5BT_enc.c` in
the upstream repo for Savitech's reference ABR logic, which maps 1:1 onto this API.

## Conformance testing

`test/ref_encode_c.c` mirrors a Rust harness added to the original crate
(`src/bin/ref_encode.rs` calling `lhdc_api`). Both encode the same deterministic
LCG-generated PCM and dump every `(written_bytes, written_frames, payload)` record.
Results are compared byte-for-byte:

- 12 configurations × 500 frames (2.5 s each): sample rates 44.1/48/96/192 kHz,
  S16 + S24, bitrate indexes 0–13 — **identical output**.
- 6 mid-stream bitrate-switch scenarios — **identical output**.
- RAM-capped builds (`96000`, `48000`) re-verified for their supported rates.

## Notes & limitations (inherited from the original)

- Stereo (2-channel) input only; mono sources must be duplicated to L/R.
- 5 ms frame duration only; one frame per `encode` call, exactly `block` samples.
- 24-bit input is *packed* 3-byte little-endian samples (not 4-byte containers).
- Little-endian targets only (compile-time checked where the compiler tells us).
- This is the encoder only. A C decoder (`liblhdcv5dec`) already exists upstream —
  see `ESP-IDF/bluedroid/external/liblhdcv5dec/` in the same repository.

## License

Apache-2.0, same as the AOSP sources this is derived from.
`src/lhdcv5_fft.c` additionally contains code derived from KISS FFT
(BSD-3-Clause, Copyright (c) 2003-2010 Mark Borgerding).
