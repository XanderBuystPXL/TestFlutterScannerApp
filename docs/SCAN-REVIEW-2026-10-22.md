# First complete RGB/depth device-package review

**Decision: capture/export and desktop intake pass; full pipeline integration remains pending.** This package cannot establish complete-room splat quality because the training route covers too little of the room. Keep the test separate until a complete route passes reconstruction and device lifecycle checks.

## Evidence identity

- Scan: `80F3900A-A1AE-44EE-892F-628B511183DF`.
- App: **0.2.1 (4)**; hardware `iPhone13,3`; iOS 26.5.
- Completed: 22 October 2026, 14:42:10.745 UTC.
- ZIP: 59,674,976 bytes; 264 payload files.
- SHA-256: `5a6d0d1b9fa56d45c6989764da38b621776f61db0ceb4843bec851a98c74fd7f`.
- Original private ZIP remains outside this repository. Prepared review data is in ignored `datasets/review-80F3900A/`, including the original metadata, contact sheet, depth overlays, alignment evidence and point clouds. The additional audit is beside it at `datasets/review-80F3900A-private-review.json`, leaving the checksummed dataset unchanged. No customer imagery or raw capture is committed.

## Checks that passed

| Check | Result |
| --- | --- |
| ZIP CRC, payload inventory and SHA-256 | All files pass; no missing frame assets |
| Diagnostics | Completed, no reported capture/package error |
| RGB / depth / confidence | 85 complete synchronized frame sets, 1920x1440 JPEG and 256x192 metric camera-Z depth/confidence |
| Calibration / poses / timestamps | Intake validation passes; camera basis, scaling and train/check separation preserved during conversion |
| Independent COLMAP reader | All 85 calibrated posed images match exported camera matrices; 37,997 training-only seed points |
| RoomPlan | 4 walls, 1 floor, 1 door, 1 window, 9 objects; JSON/counts and nested USDZ CRC pass |
| Node metadata | Actual binary plist, despite `.json` suffix; 16 string-to-identifier mappings refer to exported room entities |
| Live/processed room alignment | All 4 walls matched; center residuals 0.98-1.10cm; maximum axis residual 0.63 degrees |
| Desktop adapter | Validation, preparation and `run_poc.py --check-only` pass |
| Desktop regression suite | All 44 tests pass, including independent interchange reading and 3 new plist regressions |

The desktop reader previously assumed JSON for node metadata and rejected this valid Apple export. It now accepts JSON/binary/XML plists, preserves original bytes and writes normalized genuine JSON for downstream consumers. This correction is entirely on the desktop; a new iPhone build is unnecessary for it.

## Geometric consistency and coverage

The private geometric audit samples every eighth depth pixel in each dimension. It uses the existing confidence, finite-depth/range and discontinuity masks. Metric points are backprojected with depth intrinsics and ARKit-to-CV poses, then projected into other frames using nearest depth pixels.

| Observation | Training pass | Check pass |
| --- | --- | --- |
| Frames | 22 | 63 |
| Duration, first to last saved frame | 8.65 seconds | 21.93 seconds |
| Camera heading span | 68.70 degrees | 291.84 degrees |
| Median reliable depth fraction | 92.38% | 88.44% |
| Median of adjacent-pair median camera-Z errors | 0.89cm | 0.98cm |
| Median adjacent-pair fraction agreeing within 10cm | 99.28% | 97.82% |

These are consistency checks within shared ARKit mapping, not independent ground truth. Occlusion, depth smoothing and confidence filtering affect them. The wall-fit residual is also not a guarantee of real-world measurement accuracy. RGB/depth overlays show broadly corresponding edges in the reviewed samples, but sensor-resolution boundaries and absolute scale still require physical review and a measured distance.

**Coverage fails for the intended complete-room reconstruction.** The training contact-sheet samples show a narrow portion of the room and ceiling; the wider room walkthrough occurs in the check pass. Of 42,383 reliable sampled check-depth points, only **53.54%** fall within any training camera frustum; **47.70%** also agree with an available training depth sample within 10cm. These percentages are sample-weighted held-out-view overlap, not a percentage of total room surface or an SfM registration score. One RoomPlan wall has no training depth samples within its finite bounds and 10cm plane distance, while check samples observe it.

The 20-training-frame minimum protects against empty exports. It does not establish room completeness. Check-only imagery/depth must remain excluded from fitting and initialization; changing its role would invalidate the current evaluation protocol.

## Work remaining for a go decision

1. Capture a complete training loop with overlapping views of every wall, floor and furniture, moving between viewpoints rather than only pivoting. Inspect the training contact sheet before relying on the package. Then record a separate shorter check loop of the same room. A suggested 1-2 minutes of training is guidance, not a duration-based acceptance rule.
2. Validate and physically review that package, including a measured room distance and depth/room placement. Preserve the original package and reports.
3. Run an actual reconstruction, inspect held-out renders/metrics, and open the exported splat with RoomPlan geometry in the target viewer. No GPU training was run on this review's insufficiently covered package; adapter preflight is not reconstruction proof.
4. Record repeated scans, cancel/interruption, force-close/restart/sharing and deletion outcomes on the phone. The single completed archive does not prove these flows or recovery of the earlier failed capture.
5. Retain the matching Codemagic logs for native tests and the device build. Continue the separate commercial-release review in `COMMERCIAL-USE.md`; file validation provides no legal approval.

The actual app remains unchanged. These results establish one successful capture/export on this particular device/build, with an interoperable data contract after the reader fix; they do not establish complete pipeline or commercial release acceptance.
