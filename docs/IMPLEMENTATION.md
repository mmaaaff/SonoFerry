# Implementation notes

Current source baseline: **SonoFerry 0.2.0 Beta 1, build 54**. App, engine and audio helper share that version. The HAL has bundle version 0.1.0/build1 and runtime revision 7. A matching engine hash is generated during each build; it is not a portable, fixed release constant.

## Audio path

System audio → SonoFerry HAL virtual output → Core Audio Tap → PCM conversion and buffering → LDAC or LHDC V5 encoder → codec packet headers / RTP → AVDTP / L2CAP → headphones.

The SwiftUI app communicates with a separate engine using versioned messages, request identifiers and session identifiers. Native helpers own capture, signaling and media transport. Session cleanup restores system output only while the app still owns it, respecting an output the user selected independently.

## Source map

| Area | Entry points |
| --- | --- |
| Menu, settings and UI | `Sources/App/SonoFerryApp.swift`, `DeviceLibraryView.swift`, `ApplicationSettingsView.swift` |
| Application state, preferences and recovery | `Sources/App/EngineClient.swift` |
| Models and capability checks | `Sources/Core/Models.swift`, `Capabilities.swift` |
| Headphone identity and profiles | `Configuration/OppoProfiles.json`, `Sources/Core/HeadphoneProfile.swift` |
| OPPO control protocol | `Sources/Core/OppoControlProtocol.swift`, `Sources/Engine/HeadsetControlService.swift` |
| Session lifecycle | `Sources/Engine/NativeSession.swift`, `NativeOutput.swift` |
| HAL and sample-rate controls | `Native/Driver/SonoFerryOutput.c`, `SystemRateControl.inc` |
| Capture and Bluetooth transport | `Native/Capture/`, `Native/Transport/` |
| LHDC codec adapter | `Native/Codec/LHDCBackend.c` |
| Build and package metadata | `scripts/build_settings.py`, `build.py`, `package.py` |

Paths within the entry-point column are relative to the repository or to the directory named earlier in the same cell.

## Beta 1 UI changes

`HighBitrateWarning` in `ApplicationPreferences.swift` presents the native confirmation for fixed LHDC 900/1000 kbps. The UI calls `EngineClient.requestApplySettings`, which verifies the current draft and device again after confirmation before invoking the existing application path. Cancel leaves playback unchanged. Suppression is saved only after a valid affirmative decision, under `suppressLHDCHighBitrateWarning` in the app's preferences domain.

Clearing application data waits for successful engine teardown, clears local files and removes the preferences domain. The warning uses that domain directly, so reset takes effect immediately and after relaunch. Failed teardown preserves data. Automatic recovery and MIDI-driven reconnection do not introduce a new warning.

The development-preview badge is removed. The footer shows `HAL` followed by the detected runtime revision, for example `HAL 7`, with unknown/unloaded states displayed explicitly. `ApplicationVersion.display` combines the numeric bundle version with `SonoFerryReleaseLabel` for the footer and About view.

## Capability and control boundaries

Device identity, advertised codec capabilities, requested settings and negotiated results are separate. Model recognition never authorizes an unverified operation. Enco X4 high-rate choices follow reported capabilities after HiRes changes. A cached product catalogue is generated from `Configuration/OppoProfiles.json`; regeneration is checked by the build. See [OPPO provenance](OPPO-CONTROL.md).

LHDC rates are 44.1/48/96/192 kHz; LDAC rates are 44.1/48/88.2/96 kHz. This describes the local implementations, not a promise that every headset accepts them. All current LHDC encoding is lossy. Fixed-rate transmission does not silently lower its target to conceal congestion.

Permission refresh and driver status refresh are separate from optional health diagnostics. The app's audio restart path does not run a 45-second CPU/doctor loop. Independent health diagnostics are opt-in.

## Public source scope

This repository contains application/native code, tests, vendored source with notices, build and packaging scripts, and these public-facing documents. Local research histories, APKs, extracted firmware/libraries, raw device logs, caches, build products and installation packages are excluded. Some source comments refer to local research records that are intentionally not distributed; public provenance is summarized in the notices and OPPO notes.

No runtime behavior was changed during preparation of this public source snapshot. Future changes should update this document and record actual validation in `ACCEPTANCE.md`, distinguishing offline checks, hardware transfer, listening and long-term tests.
