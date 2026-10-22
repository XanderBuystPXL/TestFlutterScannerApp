# RoomPlan capture pipeline test

Standalone Flutter/Swift app for **cloud build → Windows install → LiDAR capture → checked reconstruction dataset**. Source version **0.2.1 (4)**. The Aproxx team app is untouched.

Captures one room using public Apple APIs: RGB photos, per-frame camera poses/intrinsics, synchronized scene depth/confidence, complete RoomPlan JSON, USDZ, node metadata, live geometry for alignment, events and checksums. Shares one ZIP. Desktop tools validate it and prepare inputs for the existing Gaussian-splat research pipeline.

**This version is implemented, not yet proven on the iPhone.** The previous geometry-only version produced a real room JSON successfully. The new capture, Codemagic build, installation, alignment and first reconstruction need [device acceptance](docs/ACCEPTANCE.md). Structural tests cannot prove physical calibration or reconstruction quality.

## Build and install

1. Connect [this separate repository](https://github.com/XanderBuystPXL/TestFlutterScannerApp) to Codemagic. Select `main`, repository YAML and workflow **RoomPlan test - unsigned iPhone IPA**.
2. Start a build. No signing credentials or App Store Connect account are needed for the unsigned workflow. Download the new `RoomPlanTest-unsigned.ipa` after all checks pass.
3. On the Windows PC connected to the phone, install [Sideloadly](https://sideloadly.io/), follow its current Apple device-component setup, and connect the unlocked iPhone by USB. Accept Trust this computer.
4. Select the IPA in Sideloadly, sign with your Apple account, complete verification and install. Trust the developer profile and enable Developer Mode when prompted. The device owner must approve phone security prompts; this does not bypass Face ID/passcode restrictions.
5. Confirm **App version: 0.2.1 (4)**. For updates, use the same signing account/bundle identifier and install over the app to retain captures. Free provisioning normally needs refreshing after seven days; see [Sideloadly's FAQ](https://sideloadly.io/faq).

### Recover the failed 0.2.0 capture

Version 0.2.1 fixes fragile file-path slicing in packaging: filesystem aliases and directory URL spellings are handled by resolving paths and comparing components. Checksums/read-back retain actual file URLs. Every indexed RGB/depth/confidence asset and its expected size is checked before packaging; a genuinely missing file is reported with its relative path and stage.

Install **over** the old app without uninstalling, using the same signing account/bundle ID. If the last failed attempt still has its capture metadata and room exports, tap **Retry saving last scan**. This uses existing files without starting the camera. It cannot recreate a genuinely deleted depth map; such a failure remains explicit and requires a new scan. Earlier completed scans stay intact. Retry diagnostics record the packager build while preserving the original capture device/build metadata.

The IPA currently tracked in `artifacts/` is **0.1.0 (1)**. It does not contain this work. Teammates may replace it with the new verified artifact; keep the version clear in `artifacts/README.md`. Never commit captures or signing credentials.

Bundle: `be.aproxx.roomplanDeviceTest`. Requires a real LiDAR iPhone/iPad, iOS 17+, RoomPlan and scene-depth support. Simulators and ordinary non-LiDAR iPhones cannot scan.

Codemagic pins Flutter **3.35.4**, revision `d693b4b9dbac2acd4477aea4555ca6dcbea44ba2` (team starter), and Xcode **16.4**, Mac mini M2. It runs Flutter checks, desktop intake tests, native simulator storage/package tests, an independent Python check of the Swift ZIP, then an unsigned arm64 release build. Logs, dependency inventories, notices and IPA are artifacts. App Store distribution needs its own current SDK/signing/privacy review.

## Capture a room

1. Obtain permission to record the space and its contents. Remove people/private documents/screens. Confirm the recording authorisation checkbox and tap **Start scan**. Allow camera access.
2. Walk slowly around a small, well-lit room. Keep overlapping views; move through the space rather than rotating in one spot. Cover walls/corners, floor, furniture and intended walkthrough areas. Photos save automatically, targeting three per second.
3. After covering the room, tap **Record check pass**. Walk a separate short route with different viewpoints. Its RGB/depth are withheld from fitting/initialization by the adapter; ARKit and RoomPlan mapping are still shared.
4. After at least ten check frames, tap **Finish**. Keep the app open and phone unlocked while saving. Completion requires processed room geometry, 20 training frames, ten check frames, camera movement, saved files and ZIP. These are sanity minima, not sufficient coverage targets.
5. **Share scan files** transfers the full unredacted ZIP to your chosen Windows destination. **Share diagnostics** exports only the latest attempt's JSON log.
6. Reopen and try sharing again. Previous completed scans survive failed/cancelled attempts. **Delete all local scans** removes complete/partial captures; shared/desktop copies need separate deletion.

Captures stay local, excluded from device backup, with complete iOS file protection. No automatic upload or Photos-library writes. A chosen share destination has its own sync/retention. The information button opens dependency licences.

Capture fails clearly on denied permission, unsupported hardware, interruption, relocalisation, missing usable depth, processing/storage errors or the 1800-frame limit. No interrupted coordinate spaces are silently joined. Partial photos/depth and diagnostics remain until deleted, without becoming completed results.

## Check the ZIP on Windows

Use Python **3.11+**. Intake needs NumPy and Pillow, no CUDA or model weights.

```powershell
py -3 -m venv .tools\intake
.\.tools\intake\Scripts\python -m pip install -r scripts\requirements.txt
.\.tools\intake\Scripts\python scripts\capture_pipeline.py validate "C:\path\scan-UUID.zip"
.\.tools\intake\Scripts\python scripts\capture_pipeline.py prepare "C:\path\scan-UUID.zip" "datasets\room-01"
.\.tools\intake\Scripts\python scripts\run_poc.py "datasets\room-01" --check-only
```

Use a new dataset folder for every conversion; existing outputs are never overwritten. Raw ZIPs belong in ignored `captures/`, prepared data in ignored `datasets/`, on an access-controlled disk outside public sync.

Validation checks exact inventory/SHA-256, timestamps, roles, image dimensions/orientation, rigid poses, depth size/units/confidence, camera rays, geometry/counts, events and capture sanity. Bounded ZIP reads reject unsafe paths, symlinks, duplicates and excessive compression. Hashes detect corruption, not sender identity.

Preparation produces:

- `images/`, `pipeline.json`: photos and explicit camera/role data.
- `sensor_depth/`: normalized training-only depth, masks, intrinsics and the trainer's report contract. `holdout_depth/` stays separate from fitting.
- `points.npz`, `preview.ply`: bounded colored **training-only** LiDAR initialization, without predicted-depth models.
- `transforms.json`: metric OpenGL/ARKit transforms and explicit train/validation filenames for compatible readers. Disable automatic orientation/rescaling when aligning geometry.
- `sparse/0/*.bin`: COLMAP PINHOLE interchange with ARKit poses and sensor points, **not SfM results**. Empty feature tracks provide no SfM registration/reprojection evidence. Use the adapter to preserve explicit roles.
- `geometry/`: original RoomPlan files and alignment fitted from matching live/processed wall IDs. No guessed interpretation of undocumented origin fields.
- `camera-path.ply`, `room-walls.ply` when alignment can be fitted, contact sheet and depth overlays for physical review. Previews retain metric capture coordinates.
- `evidence/`, `intake-report.json`, `dataset-checksums.json`: original metadata and conversion provenance.

Review overlays, contact sheet and point clouds before training. Open PLYs together in an approved viewer. Check upright orientation, distances, depth edges, camera positions, wall placement and drift. Follow [ACCEPTANCE.md](docs/ACCEPTANCE.md).

## Existing GPU reconstruction

In the existing CUDA PoC environment, use this wrapper rather than the Android/SfM loader directly:

```powershell
python scripts\run_poc.py "datasets\room-01" --poc-root "..\Research\PoC-Android" --out "datasets\room-01-run" --steps 3000 --factor 2 --alignment-reviewed
```

`--alignment-reviewed` records an operator acknowledgement, not automatic certification. The wrapper replaces the trainer's scene loader **inside that Python process only**, preserving roles, calibration, normalization and train-only sensor depth. Research and the team app are not edited. Keep the PoC's CUDA/PyTorch/gsplat/pycolmap/OpenCV/SciPy environment; do not replace it with the small intake requirements.

Normalization uses training cameras only. CV poses use `T_cv = T_arkit @ diag(1,-1,-1,1)`. Depth in positive camera-Z metres receives the same scale as points/translations. Reverse `scene.json` origin/scale to put splats in metric capture coordinates; use `geometry/alignment.json` for processed-room correction.

The wrapper reuses held-out RGB metrics/splat export and records source fingerprints in `iphone-intake.json`. The PoC's existing metric note about an interleaved path is superseded by that record: this adapter uses a separate check pass with shared mapping. Process completion alone does not prove room completeness or commercial readiness.

## Interface and development

Contract: [CAPTURE-FORMAT.md](docs/CAPTURE-FORMAT.md). Channel: `be.aproxx.roomplan_device_test/scanner`.

| Method | Behaviour |
| --- | --- |
| `getStatus` | Support, permission, latest result, capture counts, `pipelineReady`, diagnostics |
| `startScan` | Completes after geometry/package commit, or returns cancellation/native error |
| `retryLatestExport` | Revalidates/repackages the latest failed or interrupted capture from existing files |
| `shareLatestResult` | One ZIP for new captures; two JSON files for legacy results |
| `shareDiagnostics` | Latest attempt's JSON log |
| `deleteAllScans` | Removes UUID attempt directories; blocked during capture/packaging |

`pipelineReady` means a completed archive exists, **not** that alignment, reconstruction or commercial approval passed. Legacy scans remain shareable with an explanation.

```powershell
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
python -m unittest discover -s scripts -p "test_*.py" -v
```

Use the intake environment for Python. Native XCTest/device compilation run on Codemagic. See [VALIDATION.md](VALIDATION.md) for actual results versus pending checks.

Commercial use is a design constraint: public Apple frameworks, Flutter notices, no bundled reconstruction model, recording disclosure, deletion and no hidden collection. [COMMERCIAL-USE.md](docs/COMMERCIAL-USE.md) records controls and remaining release decisions. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) separates app dependencies from optional research tooling.

## Primary references

- [Apple shared-session scanning](https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure)
- [Apple depth data](https://developer.apple.com/documentation/arkit/ardepthdata)
- [RoomPlan export and metadata](https://developer.apple.com/videos/play/wwdc2023/10192/)
- [Codemagic Xcode image](https://docs.codemagic.io/specs-macos/xcode-16-4/)
- [Sideloadly](https://sideloadly.io/faq)
