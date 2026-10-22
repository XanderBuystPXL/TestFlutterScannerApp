# Verification record

Source **0.2.1 (4)**, checked on Windows, 22 October 2026. Flutter 3.35.4 / Dart 3.9.2; Python 3.12.14, NumPy 2.3.5, Pillow 12.3.0. Independent COLMAP reader: pycolmap 4.2.1, installed only in ignored local tools.

## Passed locally for the new source

- Dart formatting and Flutter analysis: clean.
- **15 Flutter tests:** recording authorisation, support checks, permission denial, completion, cancellation preserving an earlier result, native errors, restart summary/role counts, sharing, deletion confirmation, missing bridge and malformed results. New tests cover retry without starting the camera/recording consent and an actionable retry failure that preserves the saved attempt.
- **41 Python tests:** old JSON checks/IPA tooling plus full synthetic package validation/preparation, timestamp/calibration/orientation rules, confidence/depth, corruption/inventory/path rejection, split isolation, train-only initialization/normalization, positive camera-Z conversion, processed/live room correction and dataset integrity. Tests also require privacy/licence assets for a full-capture IPA and reject an old app version. Eight native-ZIP-reader regressions cover equivalent NFC/NFD UTF-8 names, content/CRC errors, extra entries, name collisions, compression and missing UTF-8 flags.
- Independent **pycolmap** read of generated binary interchange: all 30 synthetic camera poses/calibrations and 570 sensor seed points read correctly. This checks serialization, not SfM registration or real-world quality.
- Codemagic YAML parsed with the expected five stages and pinned SDKs. All generated stage scripts and packaging script passed shell syntax checks.
- Property lists parsed; privacy manifest is registered as a Runner resource and new Swift files are registered in Sources.
- Team repo `3DViewerAproxx`: clean and unchanged at `8d076b5`.

All newly generated images/depth/geometry in automated tests are explicitly synthetic. They are not a real room, real-device acceptance, GPU training or legal approval. Local checks do not compile iOS; Flutter tests mock the platform channel.

## Existing real-device evidence

The supplied files from **0.1.1 (2)** were rechecked together. Diagnostics mark the scan completed on hardware `iPhone13,3`, iOS 26.5. Counts match the JSON: **7 walls, 1 floor, 1 door, 1 window, 3 objects, 0 openings**. The exact JSON read-back event is present. Customer room files remain outside this repo.

This establishes the previous RoomPlan geometry export, not RGB/depth capture or splat inputs. The old framework-identity comparison was fixed before that successful export.

The tracked `artifacts/RoomPlanTest-unsigned.ipa` remains original **0.1.0 (1)**. It is not replaced or relabelled as the new build.

## Codemagic native evidence and simulator-lifecycle fix

The build log supplied on 22 October 2026 confirms **22 native XCTest cases passed, zero failures**, on an iOS 18.5 simulator with Xcode 16.4. This includes simulator compilation, storage, cancellation/recovery, JSON/count/byte checks, padded depth rows, matrix ordering, capture minima, deletion, missing-archive recovery, SHA-256/CRC vectors and package commit/sharing.

Initially, after `TEST SUCCEEDED`, `simctl get_app_container` failed with CoreSimulator error 405, `Unable to lookup in current state: Shutdown`. Explicit boot/wait gates were added before tests and container lookup. The next supplied log confirms this correction worked: the simulator was running, the fixture was retrieved and Python reached ZIP verification.

That rerun passed all 22 native tests again and passed the ZIP CRC check, then failed an exact filename assertion. The log does not include actual entry names. A valid decomposed-Unicode `fi\u0308le.txt` fixture reproduces the identical failure against the old checker, which expected composed `f\u00efle.txt`. The reader now compares canonical NFC names while reading the original entries and still rejects collisions, incorrect contents/CRC, non-UTF-8 Unicode names, compression and unexpected files. Failures show actual escaped filenames, and Codemagic retains the verification log/fixture. Actual archive-name confirmation and the corrected cloud rerun remain pending.

Simulator success alone does not compile the RoomPlan-only device branches. The later supplied 0.2.0 phone evidence below establishes that a device build ran through capture; no new 0.2.1 IPA/native test run has been supplied. No macOS/Xcode is available locally; the accessible browser session requires Codemagic sign-in.

## Device packaging failure and 0.2.1 recovery

The supplied `diagnostics 2.json` is from 0.2.0 (3), iPhone13,3 / iOS 26.5. It reports 109 written frame records (32 train, 77 check), no missing-depth observations/writer drops, a 0.762m training span, processed RoomPlan geometry (4 walls, 1 floor, 1 door, 1 window, 5 objects), and successful room JSON read-back. It then fails during packaging with NSCocoaErrorDomain code 4, `frame-000075.f32` not found. No completed ZIP was established, and no raw capture was supplied for independent inspection.

The code derived relative paths by subtracting a character count from separately obtained URL paths, then rebuilt checksum read-back URLs from those strings. That is unsafe for aliases such as /var versus /private/var and differing directory URL spellings. Version 0.2.1 resolves roots/entries, compares path components/containment and retains actual source URLs through checksum read-back. A frame inventory/size preflight now reports genuinely missing/truncated assets with relative path and stage. The old diagnostic does not include the full failing path, so it cannot alone establish whether that particular depth file was absent or addressed incorrectly.

The new Retry saving last scan action revalidates/repackages retained files without reacquiring the camera or inventing missing frames. Error diagnostics preserve the stage/relative path and remove stale completion timestamps. Original capture metadata stays intact; retry events record the new packager build.

**28 native XCTest cases are defined**: six new regressions cover aliased/trailing-slash roots, a 109-frame export through an alias, actually missing frame 75, truncated depth, retry without recapture and child-symlink rejection. These new native tests await Codemagic. All Swift sources passed a local tree-sitter syntax parse; this is not Swift type-checking or device acceptance.

## Still required before integration

1. Successful corrected Codemagic workflow through 28 native tests, ZIP verification, device build and new 0.2.1 (4) IPA.
2. Install over the existing LiDAR iPhone app and retry the retained capture; independently validate a completed RGB/depth/RoomPlan ZIP. If assets are actually missing, retain diagnostics and capture a new scan.
3. Physical alignment/scale/coverage review and exact exported-data checks.
4. First actual GPU reconstruction, held-out renders/metrics and target-viewer alignment.
5. Real-device cancellation, repeated scans, restart/sharing, interruption and deletion checks.
6. Commercial release decisions/approvals in `docs/COMMERCIAL-USE.md`.

Follow `docs/ACCEPTANCE.md`; retain actual evidence rather than replacing pending entries with assumptions.
