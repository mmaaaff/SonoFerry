# SonoFerry

A macOS menu bar app for LDAC and LHDC V5 audio over built-in Bluetooth, with dedicated optimizations and integrated controls for OPPO headphones.

**Current version: 0.2.0 Beta 2 (build 55).** Requires an Apple Silicon Mac running macOS 15.4 or later. The app currently uses a Chinese-language interface.

[Download Beta 2](https://github.com/mmaaaff/SonoFerry/releases/tag/v0.2.0-beta.2) — the release includes the complete installer, standalone uninstaller and SHA-256 checksums. Read the installation steps below before upgrading. This is a pre-release; the app is ad-hoc signed and not notarized.

SonoFerry combines a virtual audio output, system audio capture and a dedicated Bluetooth audio engine. Pair your headphones in macOS, add them to SonoFerry, then select an available high-quality codec. Codec and control availability depend on the connected headphones and their reported capabilities.

## Features

- LDAC and LHDC V5 encoding over the Mac's built-in Bluetooth radio.
- Adaptive or fixed bitrate, sample-rate selection and per-device preferences.
- OPPO headphone controls, including supported noise cancellation modes, HiRes, presets, EQ, BassWave, gestures and battery status.
- Device and output switching, ordered session cleanup and bounded connection recovery.
- Optional software volume control, local buffering controls and sanitized diagnostic export.
- A confirmation before applying LHDC 900 or 1000 kbps, with a remembered “Don't show again” choice. Clearing application data restores the warning.

OPPO Enco X4 is the primary device used for OPPO-specific development. The model catalogue includes other OPPO devices, but catalogue recognition does **not** mean every model or feature has been tested. Sony WH-1000XM5 has also been used for LDAC playback checks.

## Beta status and limitations

This is an independent, unofficial project. It is not affiliated with or endorsed by OPPO, Sony, Savitech or DYNAUDIO, and it does not claim codec product certification.

- LHDC V5 is currently **lossy**. LHDC Lossless / mHDT is not implemented.
- Microphone/HFP transport and headphone hardware volume control are not implemented. Software volume is optional and disabled by default.
- Short real-device listening checks and offline codec tests have passed in development. Long playback sessions, repeated reconnects, sleep/wake and failure recovery still need broader testing. These historical checks are not a full hardware qualification of Beta 2.
- The minimum build target is macOS 15.4; lower-target builds and offline checks do not establish actual playback compatibility on macOS 15.4. Target-system hardware validation is still required. Intel Macs are not supported by the current build.
- Bluetooth transport uses private macOS interfaces and may be affected by OS updates.

See [validation scope](docs/ACCEPTANCE.md) and [implementation notes](docs/IMPLEMENTATION.md).

## Build from source

Install full Xcode and its command-line tools, and make Python 3 available. Run these commands on an Apple Silicon Mac from the repository root:

```sh
python3 scripts/build.py
python3 scripts/test.py
python3 scripts/package.py
python3 scripts/verify-product.py --package dist/SonoFerry-0.2.0-Beta2.pkg
```

Normal builds use the checked-in, checksum-pinned dependencies and do not download code. The build creates an ad-hoc-signed app and matching HAL plugin; it does not install them or restart system audio. The package is not Developer ID signed or notarized.

Outputs:

- `dist/SonoFerry.app`
- `dist/SonoFerry-0.2.0-Beta2.pkg`
- `dist/卸载 SonoFerry.app` — standalone uninstaller

Optional independent decoder tests download pinned, checksum-verified test dependencies into ignored `work/` directories:

```sh
python3 scripts/fetch-reference-decoder.py
python3 scripts/test.py --reference
```

These decoders are not included in the app or installer. The normal test runner uses offline fixtures. Files named `*Integration*` and experimental tools are separate, opt-in hardware exercises; do not run them as ordinary unit tests.

## Install and use

1. Stop playback, stop SonoFerry's HD audio session and quit the app normally. Wait for cleanup and confirm macOS is using a native output again.
2. Install the complete matching package. Installation needs administrator authorization.
3. Restart the Mac, or reload Core Audio **once** after installation:

   ```sh
   sudo /usr/bin/killall -TERM coreaudiod
   ```

   This interrupts all application audio briefly. The installer does not restart audio itself. Do not repeatedly restart the service to hide a persistent failure.
4. Open `/Applications/SonoFerry.app`, grant Bluetooth and system audio recording permissions when requested, and add your paired headphones.

Use the installed app for real playback. An engine rebuild changes its signing identity: always install its matching HAL plugin and reload it before use. Mixing an engine and HAL from different builds can cause authorization failures. Keep SIP enabled.

For an optional, bounded health check while playback is stopped:

```sh
python3 scripts/check-install.py --version 0.2.0 --build 55
```

This checks installed versions and signatures, the HAL's engine authorization hash, bounded diagnostics, and process samples over roughly 45 seconds. It does not install, restart audio, play sound or change headphone settings. Logs may contain local paths or device information; review them before sharing.

To uninstall, stop playback and quit SonoFerry, then open `dist/卸载 SonoFerry.app`. App and HAL removal require administrator authorization. Device preferences and diagnostic data can optionally be retained. Reload system audio or restart the Mac afterwards.

## Privacy and issue reports

Prefer the app's sanitized diagnostic export for public issue reports. Do not upload raw phone bug reports, Bluetooth addresses, personal file paths, tokens or entire local diagnostic directories. Describe the app version, macOS version, headphone model, selected codec/rate and reproduction steps.

## License and acknowledgements

Original SonoFerry code is available under the [MIT license](LICENSE). Adapted code and dependencies retain their own licenses and copyright notices; see [third-party notices](THIRD-PARTY-NOTICES.md).

SonoFerry builds on Acouplet, AOSP libldac, the community LHDC V5 encoder and Apple's NullAudio sample. Headphone feature names and the vendor-derived DYNAUDIO/noise graphics identify existing headphone features; those third-party marks and artwork are **not** covered by the MIT license. The “CO-CREATED WITH DYNAUDIO” badge refers to the headphone's tuning, not a collaboration with SonoFerry. Source provenance and licensing exceptions are documented in the third-party notices.
