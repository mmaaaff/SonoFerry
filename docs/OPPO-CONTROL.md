# OPPO control and provenance

SonoFerry's OPPO adapter, transaction handling and bounded stream parser are independently implemented. Public protocol observations from [OPPOEarPhoneForHyperOS](https://github.com/GreenTeodoro839/OPPOEarPhoneForHyperOS), including `Packets.kt` and `.research/PROTOCOL_FINDINGS.md`, were consulted during development. Enco X3 observations were not assumed to establish Enco X4 support.

Subsequent Enco X4 work used local observations of a user-owned device and the Melody 17.6.3 phone component. Those APKs, extracted libraries, original resource XMLs and raw phone traces are not included in this repository. Product ID `06EC10` identifies Enco X4 in the implemented catalogue. `Configuration/OppoProfiles.json` contains 58 OPPO catalogue entries; catalogue membership is not a claim of verified support for every operation.

Control access is based on a confirmed product ID, supported service/dialect and current capabilities. Bluetooth names alone do not grant control support. Writes are correlated with request and generation identifiers; stale replies cannot confirm a newer operation. HiRes changes require refreshed codec capabilities. Audio and control channels use bounded cleanup and recovery gates.

The implementation includes supported noise modes, battery state, HiRes, gestures, preset/EQ management, BassWave and other reported settings. Availability differs by model. Personal hearing calibration is limited to controlling already stored results; the app does not reproduce the phone's full setup flow. Mac wear-based automation is not enabled as a complete, validated feature.

Vendor-derived UI artwork is retained to identify the headphone's existing features. The DYNAUDIO preset badge, real-time noise badge and four noise mode graphics are not MIT-licensed; their provenance and rights exceptions are stated in `THIRD-PARTY-NOTICES.md`. This project does not imply manufacturer endorsement or ownership of those marks.
