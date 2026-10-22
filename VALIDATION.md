# Verification record

Checked on Windows on 22 October 2026, using Flutter 3.35.4 / Dart 3.9.2.

## Passed locally

- Dart formatting: three files checked; no remaining formatting changes.
- Flutter analysis: no issues found.
- Flutter automated checks: **10 passed**, including support checks, permission denial, completion and sharing, cancellation preserving an earlier result, native errors, restoring a saved summary, a missing bridge and malformed native results.
- Python tooling checks: **11 passed**, including matching exports, count mismatches, cancelled/empty/incomplete exports, geometry fields, IPA layout/device metadata and simulator selection.
- Codemagic YAML: parsed successfully; five stages and pinned Flutter/Xcode versions confirmed.
- Shell syntax: packaging script and all five Codemagic stages passed `bash -n`.
- iOS property lists: parsed successfully. Camera permission text and iOS 17 deployment settings are present.
- Team repository: no changes; HEAD remained `8d076b5` during verification.

The Flutter tests mock the native channel. Python/native storage fixtures are synthetic and are not actual RoomPlan captures. The IPA unit tests check synthetic archive metadata; they do not prove compilation, signing or installation.

## Awaiting the Codemagic Mac

- Compile the native Swift implementation with Xcode 16.4.
- Run the **7 native storage tests** on an iOS simulator.
- Compile the real arm64 iPhone release build.
- Produce and verify `RoomPlanTest-unsigned.ipa`.

The source/configuration is prepared for the separate remote repository `XanderBuystPXL/TestFlutterScannerApp`. No Codemagic account has been connected from this workspace. No IPA has been built here.

## Awaiting the LiDAR device

- Sign/install the IPA with Sideloadly and launch it independently.
- Capture a real room and validate the exported files on Windows.
- Exercise denied permission, cancellation, a second capture, background interruption and persistence after restarting.
- Inspect the room's actual coverage and geometry.

Use the device acceptance checklist in `README.md`. A passing local test suite alone does not complete device acceptance.
