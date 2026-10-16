# Validation scope

## 2026-10-16 — 0.2.0 Beta 2 / build55

The minimum target is now macOS15.4 on arm64 for the app, engine, capture helper, HAL and standalone uninstaller (1.5/build6). Runtime/codec/headphone-control source is unchanged from Beta1. All executable deployment targets and bundle minimum-system values were checked; the new engine hash matches the bundled and installed-payload HAL copies.

A complete build, all 87 core tests, the full offline regression suite, independent LDAC/LHDC decoding tests, strict signatures and expanded-package/payload checks passed on the macOS27.2 build host. Existing test-code unused-result and external reference-decoder return warnings remain; the production build completed without new warnings. The uninstaller ZIP was extracted and its strict signature checked.

This is not macOS15.4 hardware acceptance. First-run permissions, HAL loading, live Bluetooth transport, listening and long-term behavior on macOS15.4 remain untested. No app/HAL installation, restart, live playback, CPU sampling or doctor check was performed. Upgrades must install the complete matching Beta2 package and reload audio once or restart the Mac.

Package: `SonoFerry-0.2.0-Beta2.pkg`, 3,323,802 bytes, SHA-256 `b89e58b42b3dca8ea4491c900a11f68ab1e3d80590f04529b071342b4588dbe3`. Uninstaller: `SonoFerry-Uninstaller-1.5.zip`. Both checksums accompany the release in `SHA256SUMS.txt`.

## 2026-10-16 — 0.2.0 Beta 1 / build54

The development build passed:

- A complete build of the app, engine, audio helper and matching HAL.
- 87 Swift core tests and the full offline test runner: app state, device library, settings, OPPO control, session recovery, capture fixtures, codec/transport fixtures, HAL fixtures, installer/uninstaller isolation checks and invalid-input guards.
- Independent LDAC and LHDC decoder round trips using pinned decoder sources and locally generated signals.
- Specific checks for 900/1000 kbps confirmation/cancellation, shared suppression, persistence after recreating the client, stale confirmation rejection, adaptive/lower-rate bypass and successful/failed data reset behavior.
- Strict component signature checks, architecture/minimum-system checks, matching HAL/engine authorization and an expanded-package comparison against the built payload and install scripts.

These checks use offline fixtures. They do not mean Beta 1 has been installed, its alert has been exercised interactively, or audio has been transmitted successfully on every target Mac. UI rendering, installation, audio-service restart, CPU/doctor checks, live listening and long-term hardware acceptance were not performed as part of that build.

A restricted-environment build initially failed at icon generation. A later build was interrupted by a source edit during compilation. Neither intermediate build was delivered; the final complete build and test run passed.

## Historical hardware evidence

Sony WH-1000XM5 LDAC and OPPO Enco X4 LHDC V5 have each had a short, approximately 24-second listening check during earlier development. Enco X4 at 48 kHz / 900 kbps was also reported to sound normal in a short test, with roughly 902 kbps encoded payload measured locally. HiRes toggling and readback have been exercised on Enco X4.

These historical results cannot establish Beta 1 long-term stability. Sustained playback, high-rate interference conditions, repeated start/stop, sleep/wake, output restoration, permission errors and crash/disconnect recovery still need broader coverage. One earlier Sony output-restoration failure requires further hardware verification. Local packet drain statistics do not prove remote decoding or listening quality.

Report new validation with the exact source/app build, installed HAL revision, device and OS, procedure, duration and observed result. Redact local paths and device identifiers before posting logs.


## 2026-10-16 — Public source snapshot

A separate, clean export of the public source files passed a complete build, the full offline test runner (`scripts/test.py`, including all 87 core tests), package creation and expanded-package verification. This confirms the public snapshot builds without the local research archive or previous compiler caches. Optional decoder tests were not repeated in this export; the unchanged codec/test sources had passed the independent decoder checks in the Beta 1 development build above.

No application or HAL installation, audio restart, live playback or headphone operation was performed. The exported runtime and test sources match Beta 1; public-facing documentation and license attribution were prepared separately.


## 2026-10-16 — Beta 1 prerelease

Published [v0.2.0-beta.1](https://github.com/mmaaaff/SonoFerry/releases/tag/v0.2.0-beta.1) from source commit `f9ce446927328d211b61c7c390110ea983dfcd14`. Assets use the clean public-source build described above, including its complete matching engine/HAL package. The installer differs in hash from the earlier local development package with the same version; it is not intended to be mixed with components from that earlier build.

Release assets are `SonoFerry-0.2.0-Beta1.pkg`, `SonoFerry-Uninstaller-1.4.zip` and `SHA256SUMS.txt`. The uninstaller ZIP was extracted locally and its strict code signature verified before upload. Release preparation did not install software, restart audio, play audio, run CPU/doctor checks or change headphone settings.
