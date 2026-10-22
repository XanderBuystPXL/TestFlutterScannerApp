# Verification record

Source **0.2.0 (3)**, checked on Windows, 22 October 2026. Flutter 3.35.4 / Dart 3.9.2; Python 3.12.14, NumPy 2.3.5, Pillow 12.3.0. Independent COLMAP reader: pycolmap 4.2.1, installed only in ignored local tools.

## Passed locally for the new source

- Dart formatting and Flutter analysis: clean.
- **13 Flutter tests:** recording authorisation, support checks, permission denial, completion, cancellation preserving an earlier result, native errors, restart summary/role counts, sharing, deletion confirmation, missing bridge and malformed results.
- **33 Python tests:** old JSON checks/IPA tooling plus full synthetic package validation/preparation, timestamp/calibration/orientation rules, confidence/depth, corruption/inventory/path rejection, split isolation, train-only initialization/normalization, positive camera-Z conversion, processed/live room correction and dataset integrity. Tests also require privacy/licence assets for a full-capture IPA and reject an old app version.
- Independent **pycolmap** read of generated binary interchange: all 30 synthetic camera poses/calibrations and 570 sensor seed points read correctly. This checks serialization, not SfM registration or real-world quality.
- Codemagic YAML parsed with the expected five stages and pinned SDKs. All generated stage scripts and packaging script passed shell syntax checks.
- Property lists parsed; privacy manifest is registered as a Runner resource and new Swift files are registered in Sources.
- Team repo `3DViewerAproxx`: clean and unchanged at `8d076b5`.

All newly generated images/depth/geometry in automated tests are explicitly synthetic. They are not a real room, real-device acceptance, GPU training, legal approval or a successful iOS compile. Flutter tests mock the platform channel.

## Existing real-device evidence

The supplied files from **0.1.1 (2)** were rechecked together. Diagnostics mark the scan completed on hardware `iPhone13,3`, iOS 26.5. Counts match the JSON: **7 walls, 1 floor, 1 door, 1 window, 3 objects, 0 openings**. The exact JSON read-back event is present. Customer room files remain outside this repo.

This establishes the previous RoomPlan geometry export, not RGB/depth capture or splat inputs. The old framework-identity comparison was fixed before that successful export.

The tracked `artifacts/RoomPlanTest-unsigned.ipa` remains original **0.1.0 (1)**. It is not replaced or relabelled as the new build.

## New native checks awaiting Codemagic

**22 native XCTest cases** are defined, including persistence, cancellation, interrupted recovery, JSON/count/byte checks, padded depth rows, matrix ordering, capture minima, deletion boundaries, missing-archive recovery, known SHA-256/CRC vectors and package commit/sharing. Codemagic additionally reads a Swift-written ZIP fixture with Python's independent zipfile implementation.

No macOS/Xcode is available locally. Thus new Swift compilation/tests and the release IPA are **pending**, not passed. The accessible Codemagic browser session redirects to sign-in; no cloud build was started from here.

## Still required before integration

1. Successful latest Codemagic native tests/device build and new 0.2.0 (3) IPA.
2. Sideload/install on LiDAR iPhone; new complete RGB/depth/RoomPlan ZIP.
3. Physical alignment/scale/coverage review and exact exported-data checks.
4. First actual GPU reconstruction, held-out renders/metrics and target-viewer alignment.
5. Real-device cancellation, repeated scans, restart/sharing, interruption and deletion checks.
6. Commercial release decisions/approvals in `docs/COMMERCIAL-USE.md`.

Follow `docs/ACCEPTANCE.md`; retain actual evidence rather than replacing pending entries with assumptions.
