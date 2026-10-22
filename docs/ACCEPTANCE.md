# Device and pipeline acceptance

Record source commit, Codemagic build ID, app version, device/iOS, scan UUID, ZIP hash and private evidence location. Use an authorised room without people/private material. Never commit raw captures here.

## Current evidence

- Geometry-only 0.1.1 (2): real room JSON and matching completed diagnostics supplied/checked on 22 October 2026.
- Full capture 0.2.0 (3): code/synthetic checks available; new Codemagic compilation/native tests, install/capture, physical alignment and first reconstruction are **pending**.
- Repeated capture, cancellation/restart/sharing/deletion on the new build: **pending**.
- Commercial product release: **pending** the decisions in COMMERCIAL-USE.md.

## Device checks

1. All Codemagic stages pass, including device Swift compilation, native XCTest and independent reading of the native ZIP fixture. Preserve logs/version.
2. Install new IPA; verify 0.2.0 (3), support, recording authorisation and camera prompts.
3. Deny camera: capture stays blocked, clear error/diagnostics remain. Allow access in Settings and retry.
4. Complete room/check pass. Share ZIP; validate inventory, hashes, counts/geometry, matching diagnostics and frame calibration.
5. Cancel during capture and processing; previous result stays shareable. Retry/complete another scan without overwriting prior attempts.
6. Background/lock/interruption fails clearly. Relaunch during processing/packaging recovers incomplete work as interrupted, never completed.
7. Force-close/reopen after success; share the same completed ZIP again.
8. Delete all local captures, including partials; relaunch and verify no scan/diagnostic remains shareable. Delete external copies separately.

## Physical and data checks

1. Run `capture_pipeline.py validate`, `prepare`, `run_poc.py --check-only`. Keep reports/checksums.
2. Inspect contact sheet: sharp overlapping views across required surfaces, no private content, correct orientation/colors. The 20/10 frame minima are insufficient evidence of room coverage.
3. Compare RGB/depth boundaries on furniture/walls, across multiple positions/orientations in both passes. Check mirroring, rotation, crop, camera-Z versus range, and scale. Review additional frames if default overlays are inconclusive.
4. Open `preview.ply`, `camera-path.ply`, `room-walls.ply` together in an approved viewer. Cameras must lie in the room, look toward observed surfaces, and show no discontinuous jumps. Compare a measured wall/distance; inspect drift, split walls, furniture doubling and missing surfaces.
5. `geometry/alignment.json`: ≥3 matched walls, median center residual ≤10cm, maximum ≤30cm, median rotation residual ≤5°. These are initial engineering limits, not customer-approved measurement accuracy. Reject insufficient matches/disagreement; never silently assume identity correction. Confirm physical alignment even if residuals pass.
6. Confirm explicit train/check roles and separate `holdout_depth/`; check RGB/depth must not enter fitting or seed points. Shared mapping remains disclosed.

Fix wrong rays/poses/alignment before training. More GPU cannot repair them. If adopting SfM fallback later, retain the research ≥85% registration gate; ARKit pose export is not 100%-registered SfM evidence.

## Actual reconstruction

1. Run wrapper in the existing licensed CUDA environment with a reviewed dataset/new output. Start at 3,000 steps for integration, then agree a final training budget.
2. Retain `iphone-intake.json`, `scene.json`, configs/fingerprints, held-out renders/PSNR/SSIM and exported splat. Open the splat in the team's target viewer.
3. Review intended walkthrough paths and surfaces for holes, floaters, texture loss and distortion. Process exit alone does not prove quality/completeness.
4. Reverse scene origin/scale into metric capture coordinates and apply measured RoomPlan correction once. Verify doors/walls line up in the target viewer.
5. Review private text/faces in public derivatives. Privacy masks must affect training/published results, not just thumbnails.

Integrate after one real package passes the chain and repeated/cancel/restart/share checks work. Evidence applies to that device/iOS/build; wider device coverage needs more testing. Upload/account security, multiroom processing and public deployment need separate acceptance.

Result record:

```text
source/build/app version:
device/iOS:
scan UUID / ZIP SHA256:
permission/cancel/repeat/restart/share/delete outcomes:
intake/physical alignment evidence:
GPU environment and dependency versions:
training outputs / held-out metrics / target viewer result:
privacy/licensing review owner:
accepted by / date / remaining limitations:
```
