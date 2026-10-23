# Continuous guided capture, 0.3.0 (5)

## User flow

Start scan, walk through the room with overlapping views, follow the map/prompts, then Finish. Users no longer allocate training/check passes. All accepted synchronized RGB/depth/pose frames are saved with the source role `capture` and are available for reconstruction.

The small map highlights depth-confirmed samples of detected walls/floor from multiple camera positions. A cyan marker shows the saved camera position/heading. Missing surface prompts identify numbered walls or the floor. Existing Apple coaching covers speed, distance, lighting and tracking conditions. Low-detail advice does not by itself prove blur or prevent finishing on a plain wall.

The single Finish action shows a review prompt when an estimated coverage or active capture-condition warning remains. Keep scanning retains the current session; Save with warning preserves a shareable package and visible warnings without certifying quality. At least 30 saved usable frames and 0.2m translation remain file-sanity requirements. The camera does not stop while reviewing a warning. Cancel/interruption/relocalization retain the existing incomplete-attempt handling, never silently merge another tracking origin.

The guidance scope is deliberately explicit: **observed walls and floor**, not unseen surfaces, furniture appearance, absolute measurement accuracy or splat quality. Furniture still needs overlapping views and visual review. Thresholds, performance, map orientation/accessibility and usability on real rooms need device testing. See [CAPTURE-FORMAT.md](CAPTURE-FORMAT.md) for the algorithm and initial limits.

## Desktop modes and provenance

Both schema 1 and 2 are readable. Schema 1 keeps its original benchmark split by default; schema 2 defaults to all-frame fitting. Output directories are new and checksummed; the original package, diagnostic log and source roles remain unchanged in evidence. Effective fitting roles are separate from `source_role`.

| Mode | Fitting | Evaluation |
| --- | --- | --- |
| `all-frames` | All accepted source frames | Disabled, explicit null scores; never training-view scores presented as held-out results |
| `automatic-holdout` | Automatic nearby-view split across the route | At least 10 held-out views; their RGB/depth never enters fitting or seed points. Correlated adjacent views/shared mapping, not independent localization |
| `preserve-split` | Original schema-1 training pass | Original schema-1 check pass; unavailable on continuous source captures |

```powershell
python scripts/capture_pipeline.py prepare "captures/scan-UUID.zip" "datasets/room-all" --mode all-frames
python scripts/run_poc.py "datasets/room-all" --check-only
# In a working CUDA environment:
python scripts/run_poc.py "datasets/room-all" --poc-root "../Research/PoC-Android" --out "datasets/room-all-run" --steps 3000 --factor 2 --alignment-reviewed
```

For this relocated Windows workspace, the read-only existing runtime can be resolved per process without editing Research or its virtual environments:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_local_poc.ps1 -Data datasets/room-all -Out datasets/room-all-run -AlignmentReviewed
```

This bypass applies to that invocation only. The helper installs/downloads nothing, uses the existing CUDA extension, redirects temporary output into this test project's ignored tools, restores environment variables, and leaves research sources unchanged. Inspect imagery, sensor/room alignment and camera path before acknowledging `AlignmentReviewed`. A new capture carrying coverage or image warnings requires `--allow-coverage-warnings` (PowerShell: `-AllowCoverageWarnings`) for an explicitly labelled diagnostic trial; warnings remain in provenance.

## Existing real scan: all-frame trial, 23 October 2026

Source: scan `80F3900A-A1AE-44EE-892F-628B511183DF`, original ZIP SHA-256 `5a6d0d1b9fa56d45c6989764da38b621776f61db0ceb4843bec851a98c74fd7f`. Its app build was 0.2.1 (4), not the new guided build. The old separate-pass dataset remains unchanged.

- A second private dataset uses **all 85 frames**, including 63 originally marked check-only. Intake and sensor/pose preflight pass. It contains 118,381 metric LiDAR seed points before fitting.
- The existing gsplat 1.5.3 / PyTorch 2.11.0+cu128 environment on an RTX 5070 Ti completed **3,000 steps**, producing **889,641 Gaussians**, a **209,956,753-byte PLY**, scene normalization and intake provenance. All 59 exported per-Gaussian fields are finite. No model weights or depth-prediction model were downloaded/used.
- Held-out evaluation is explicitly disabled: PSNR/SSIM are null. Reference images were used for fitting, so comparisons cannot establish independent quality.
- Seven fitted-camera renders and seven camera positions shifted 15cm were inspected. Walls and the broad room appearance reconstruct; furniture edges, fine objects and shifted viewpoints still show blur/distortion/floaters. This short fit is a pipeline smoke test, not final walkthrough acceptance. Target-viewer alignment/quality and an agreed final training budget remain pending.
- An offline mathematical replay of the new surface-sampling rule using saved depth/poses and final live geometry gives wall multi-view sample fractions **95.8%, 100%, 62.5%, 70.8%**, floor **41.7%**. The first 22 frames alone give **50%, 29.2%, 0%, 0%**, floor **16.7%**. The full ordinary walkthrough clears the initial coverage rule; the prematurely separated subset does not. This is not execution of the Swift engine on a phone and does not validate live geometry timing/performance or physical accuracy.

Private artifacts (ignored, never pushed):

```text
datasets/room-80F3900A-all-frames/
datasets/room-80F3900A-all-frames-run/
  point_cloud.ply
  checkpoint.pt
  scene.json
  config.json
  iphone-intake.json
  result.json
  eval/step-003000/metrics.json
  private-fit-preview.jpg
  private-preview-note.json
```

## Remaining acceptance

Build/install 0.3.0 (5) through Codemagic; retain native XCTest/device-build logs. Test guidance/quality warnings and responsive map on actual phones and representative furnished/reflective rooms. Verify keep-scanning/finish/save-warning, cancellation/interruption, repeated scans, restart/sharing/deletion, and export compatibility. Reconstruct a guided capture, inspect held-out development tests where appropriate, and verify the splat/RoomPlan transforms in the actual viewer. Commercial-release review remains separate in [COMMERCIAL-USE.md](COMMERCIAL-USE.md). The Aproxx app remains unchanged.

Scanner-side motion filtering and native JSON metadata normalization were adapted from the teammate-provided 0.2.2 patch; its old check-pass gate, timed override and desktop clipping were not adopted. See [patch review](PATCH-REVIEW-2026-10-23.md).
