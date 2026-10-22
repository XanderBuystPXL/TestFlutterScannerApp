# Verification record

Checked on Windows on 22 October 2026, using Flutter 3.35.4 / Dart 3.9.2.

## Passed locally

- Dart formatting: three files checked; no remaining formatting changes.
- Flutter analysis: no issues found.
- Flutter automated checks: **10 passed**, including support checks, permission denial, completion and sharing, cancellation preserving an earlier result, native errors, restoring a saved summary, a missing bridge and malformed native results.
- Python tooling checks: **13 passed**, including matching exports, count mismatches, cancelled/empty/incomplete exports, geometry fields, omitted collections, IPA layout/device metadata and simulator selection.
- Codemagic YAML: parsed successfully; five stages and pinned Flutter/Xcode versions confirmed.
- Shell syntax: packaging script and all five Codemagic stages passed `bash -n`.
- iOS property lists: parsed successfully. Camera permission text and iOS 17 deployment settings are present.
- Team repository: no changes; HEAD remained `8d076b5` during verification.

The Flutter tests mock the native channel. Python/native storage fixtures are synthetic and are not actual RoomPlan captures. The IPA unit tests check synthetic archive metadata; they do not prove compilation, signing or installation.

## Original Codemagic build 0.1.0 (1)

The artifacts supplied in `artifacts/TestFlutterScannerApp_1_artifacts.zip` confirm a successful simulator build, **7 native storage tests with zero failures**, and a successful iPhone release build. The shared IPA metadata identifies it as 0.1.0 (1), and its package structure passed local verification.

The supplied phone photo confirms that this build installed, launched, obtained camera permission and received a processed room. Its old reconstructed-room comparison rejected the export, so successful file generation on the device was not established.

## Save-check fix 0.1.1 (2)

- Replaced framework-object identity comparison with direct encoded JSON validation and exact byte-for-byte disk read-back.
- Kept wall geometry and all captured collection counts checked, with per-field errors. Omitted empty collections are accepted.
- Added expected counts, byte counts and validation strategy to diagnostics, and a visible app version on the home screen.
- Added **8 native regression tests** (15 total) for framework-independent JSON validation, omitted collections, specific count errors, missing geometry, malformed JSON, same-length byte changes and exact saved content.

Flutter analysis, all 10 Flutter tests and all 13 Python tooling tests passed locally after this fix. The **updated 15 native tests and the new iPhone build remain pending the next Codemagic run**. The old shared IPA has deliberately not been relabelled as the fixed build.

## Awaiting the LiDAR device

- Install the new 0.1.1 (2) IPA over the existing test app and confirm its version on the home screen.
- Capture a real room and validate the exported files on Windows.
- Exercise denied permission, cancellation, a second capture, background interruption and persistence after restarting.
- Inspect the room's actual coverage and geometry.

Use the device acceptance checklist in `README.md`. A passing local test suite alone does not complete device acceptance.
