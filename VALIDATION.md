# Verification record

Current source **0.3.0 (5)**, checked on Windows, 23 October 2026. Earlier 0.2.1 results below are retained as history. Flutter 3.35.4 / Dart 3.9.2; Python 3.12.14, NumPy 2.3.5, Pillow 12.3.0. Independent COLMAP reader: pycolmap 4.2.1, installed only in ignored local tools.

## Current 0.3.0 verification

- Flutter analysis and formatting clean; **18 widget/service tests pass**, including restart/share of continuous captures with warnings and explicit unverified-reconstruction wording.
- **57 Python tests pass**, including schema-2 captures/warnings, legacy compatibility, explicit all-frame trials without source mutation, automatic holdout/seed isolation, rejection of isolated held-out views, null rather than fabricated all-fit scores, and four Xcode project/resource graph regressions.
- **37 native XCTest cases are defined**, nine additions for motion filtering, JSON metadata/checksums and stationary/translated viewpoints, late/new/unseen geometry, floor detection, depth confidence/occlusion, active coaching/tracking, continuous report requirements and shareable warning-package storage. The supplied build-7 screenshot shows the cloud native-test stage succeeded; detailed results/counts were not supplied. No local Xcode is available. All eight Swift files pass the local syntax parser; this is not type-checking.
- Versioned continuous captures and bounded subsampled depth guidance were checked locally. The corrected Xcode graph has 68 unique object IDs and resolves both the application privacy resource and guidance source. Codemagic YAML and all five generated stage scripts plus the packaging script pass local checks; corrected IPA/device execution remain pending.
- The original real 0.2.1 ZIP remains unchanged. A new private **85-frame** fit completes 3,000 actual CUDA training steps and exports **889,641 Gaussians**. Independent PLY read finds all 59 fields finite. Fitted and 15cm-shifted-camera renders were inspected; furniture/detail artifacts remain. No held-out scores are claimed.
- Offline sensor/geometry replay suggests the full ordinary walkthrough clears the initial observed-wall/floor coverage rule, while its original 22-frame training subset fails. This does not run or validate the live Swift guidance on an iPhone.
- The Windows reconstruction helper resolves the moved read-only research runtime and passes actual-dataset preflight without editing it. Raw/derived room data and previews remain ignored. `3DViewerAproxx` is unchanged.

[Guided capture implementation, reproduction and trial limits](docs/GUIDED-CAPTURE.md). **Next gate: a successful corrected Codemagic packaging run and real-device acceptance of 0.3.0.** Further reconstruction work is parked; target-viewer/full-room quality remains a later acceptance item. Earlier requests for an end-user separate training/check walk are superseded by continuous capture; separate evaluation remains a development operation.

## Codemagic build 7 privacy-manifest packaging fix

The supplied screenshot for commit `7e0175a` shows the simulator/native-test and unsigned iPhone release stages succeeded, then packaging failed with `Missing application privacy manifest`. The screenshot does not include individual XCTest results or their count. This establishes the cloud stages ran successfully for that commit, but not a valid final IPA.

Source inspection found two duplicate Xcode object IDs: `CaptureGuidance.swift` reused the privacy manifest's build-file and file-reference IDs. The guidance entries now use distinct IDs; `PrivacyInfo.xcprivacy` remains in Runner's Resources phase. Privacy declarations and final IPA validation are unchanged.

An early CI guard checks duplicate IDs and resolves Runner's resource/source graph. Four regressions cover the original collision, missing privacy-resource membership, wrong guidance-source reference and the corrected graph. Packaging also checks and lints the manifest inside the compiled app before creating the IPA. All 57 Python tests and six shell-script syntax checks pass on Windows. A corrected cloud build is still required to confirm actual resource copying and final IPA validation; no local Xcode is available.

## Historical 0.2.1 local verification

- Dart formatting and Flutter analysis: clean.
- **15 Flutter tests:** recording authorisation, support checks, permission denial, completion, cancellation preserving an earlier result, native errors, restart summary/role counts, sharing, deletion confirmation, missing bridge and malformed results. New tests cover retry without starting the camera/recording consent and an actionable retry failure that preserves the saved attempt.
- **44 Python tests:** old JSON checks/IPA tooling plus full synthetic package validation/preparation, timestamp/calibration/orientation rules, confidence/depth, corruption/inventory/path rejection, split isolation, train-only initialization/normalization, positive camera-Z conversion, processed/live room correction and dataset integrity. Tests also require privacy/licence assets for a full-capture IPA and reject an old app version. Eight native-ZIP-reader regressions cover equivalent NFC/NFD UTF-8 names, content/CRC errors, extra entries, name collisions, compression and missing UTF-8 flags. Three new node-map regressions cover Apple binary/XML property lists, genuine JSON normalization with exact original-byte preservation, and invalid value rejection.
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

Simulator success alone does not compile the RoomPlan-only device branches. The later phone evidence below establishes that 0.2.0 ran through capture and 0.2.1 produced a completed package. The new 0.2.1 native-test/build logs have not been supplied. No macOS/Xcode is available locally; the accessible browser session requires Codemagic sign-in.

## Device packaging failure and 0.2.1 recovery

The supplied `diagnostics 2.json` is from 0.2.0 (3), iPhone13,3 / iOS 26.5. It reports 109 written frame records (32 train, 77 check), no missing-depth observations/writer drops, a 0.762m training span, processed RoomPlan geometry (4 walls, 1 floor, 1 door, 1 window, 5 objects), and successful room JSON read-back. It then fails during packaging with NSCocoaErrorDomain code 4, `frame-000075.f32` not found. No completed ZIP was established, and no raw capture was supplied for independent inspection.

The code derived relative paths by subtracting a character count from separately obtained URL paths, then rebuilt checksum read-back URLs from those strings. That is unsafe for aliases such as /var versus /private/var and differing directory URL spellings. Version 0.2.1 resolves roots/entries, compares path components/containment and retains actual source URLs through checksum read-back. A frame inventory/size preflight now reports genuinely missing/truncated assets with relative path and stage. The old diagnostic does not include the full failing path, so it cannot alone establish whether that particular depth file was absent or addressed incorrectly.

The new Retry saving last scan action revalidates/repackages retained files without reacquiring the camera or inventing missing frames. Error diagnostics preserve the stage/relative path and remove stale completion timestamps. Original capture metadata stays intact; retry events record the new packager build.

**28 native XCTest cases are defined**: six new regressions cover aliased/trailing-slash roots, a 109-frame export through an alias, actually missing frame 75, truncated depth, retry without recapture and child-symlink rejection. These new native tests await Codemagic. All Swift sources passed a local tree-sitter syntax parse; this is not Swift type-checking or device acceptance.

## Completed 0.2.1 real-device package

The subsequently supplied `scan-80F3900A-A1AE-44EE-892F-628B511183DF.zip` is from **0.2.1 (4)** on iPhone13,3 / iOS 26.5. ZIP CRC, all 264 files/checksums, calibration, depth/confidence, roles, geometry counts and completed diagnostics pass. The independent COLMAP reader recovers all 85 cameras/poses and 37,997 training-only sensor seed points correctly. Desktop preparation and adapter preflight pass after accepting Apple's binary-property-list node map despite its `.json` suffix. This desktop-only correction requires no phone rebuild.

The capture contains **22 training / 63 check frames**. The training route lasts 8.65 seconds and spans only 68.70 degrees of camera heading. Contact-sheet review and sampled depth reprojection identify insufficient training coverage: 46.46% of held-out depth samples lie outside every training camera frustum. The geometry and neighboring-depth consistency checks are encouraging but are not an independent measurement-accuracy guarantee. This package does **not** establish full-room splat quality or complete integration acceptance.

See [the detailed scan review](docs/SCAN-REVIEW-2026-10-22.md) for package identity, methods, results and limits. Raw files, converted datasets and private inspection artifacts remain excluded from Git.

## Historical open items from the first 0.2.1 review

1. Retain corrected Codemagic logs for 28 native tests, ZIP verification and device build. The supplied completed 0.2.1 package proves device capture/export execution, not that the entire CI workflow or all tests passed.
2. Record a complete, overlapping **training** route around the whole room, then a separate shorter check route. The current package passes file validation but fails sufficient training coverage; do not relabel check frames as training to manufacture acceptance. Retry recovery of the older failed capture remains unverified.
3. Repeat physical alignment/scale/coverage review on the new package; confirm scale against a real measurement. Current exact exported-data checks pass.
4. First actual GPU reconstruction, held-out renders/metrics and target-viewer alignment on a sufficiently covered package. No actual training run was performed in this review because this capture fails the coverage prerequisite.
5. Real-device cancellation, repeated scans, restart/sharing, interruption and deletion checks.
6. Commercial release decisions/approvals in `docs/COMMERCIAL-USE.md`.

Follow `docs/ACCEPTANCE.md`; retain actual evidence rather than replacing pending entries with assumptions.
