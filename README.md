# RoomPlan device test

A standalone Flutter app to test this route: **Codemagic build → Windows sideload → real LiDAR scan → JSON export**. It is independent of the Aproxx team repository.

The Flutter screen opens a small native Swift RoomPlan scanner. Finish saves Apple's complete `CapturedRoom` JSON and a diagnostic log. The app reads the room back before reporting success. Previous completed scans remain available after failed or cancelled attempts.

This is a geometry/export test. It does not capture RGB datasets or depth maps, generate USDZ or splats, upload scans, or implement authentication.

## Requirements

- A real LiDAR-capable iPhone or iPad running **iOS 17 or later**. RoomPlan support is checked at runtime.
- A separate remote Git repository and a Codemagic account to run the build. A personal Mac is not required.
- Windows, a USB data cable, Sideloadly and an Apple account for installation.
- No paid Apple Developer membership is assumed. Free-account apps need refreshing after **7 days** and are subject to Apple's sideloaded-app limits.

The app is named **RoomPlan Test**, with bundle ID `be.aproxx.roomplanDeviceTest`.

## 1. Open the standalone repository

Repository: [XanderBuystPXL/TestFlutterScannerApp](https://github.com/XanderBuystPXL/TestFlutterScannerApp).

The existing local copy is already a separate Git repository. To get another copy, run:

```powershell
git clone https://github.com/XanderBuystPXL/TestFlutterScannerApp.git
cd TestFlutterScannerApp
```

Connect this repository to Codemagic, rather than the team repository or the parent `IT-Project` folder. `.tools/`, build outputs, signing files and local settings are ignored. No signing credentials belong in this repository.

## 2. Build in Codemagic

1. Connect Codemagic to the **new standalone repository** and add it as an app.
2. Choose the YAML configuration from the repository root, `codemagic.yaml`.
3. Select the `main` branch and workflow **RoomPlan test - unsigned iPhone IPA** (`roomplan-device-test`). Start the build manually.
4. Leave iOS signing and App Store Connect integration unconfigured. This workflow deliberately produces unsigned output for local re-signing.
5. After all stages succeed, download **RoomPlanTest-unsigned.ipa** from the build artifacts.
6. If a stage fails, download its build logs. Do not treat a failed or skipped native build as successful verification.

The configuration pins **Flutter 3.35.4**, revision `d693b4b9dbac2acd4477aea4555ca6dcbea44ba2`, matching the team starter at the time this test was created. It pins **Xcode 16.4** on Codemagic's Mac mini M2 image. These settings are intended for this sideloaded test, not App Store submission.

The workflow runs Flutter analysis and tests, Python file/package checks, a simulator build and native storage tests, then an unsigned **arm64 iPhone release build**. It packages `Payload/Runner.app` into the IPA and verifies its layout and device metadata. Simulator tests cannot exercise RoomPlan capture.

## 3. Install from Windows with Sideloadly

1. Download Sideloadly from [its official site](https://sideloadly.io/). Follow its current Windows instructions for the Apple device components; it currently requests Apple's web versions of iTunes and iCloud rather than the Microsoft Store versions.
2. Connect the unlocked iPhone by USB. Accept **Trust this computer** on the phone and confirm it appears in Sideloadly.
3. Select **RoomPlanTest-unsigned.ipa** in Sideloadly. Keep the normal Apple-account signing/install mode; no jailbreak or injected libraries are needed.
4. Sign in with your own Apple account and complete Apple's verification prompts. Start installation. Sideloadly signs the app before installing it; an unsigned IPA cannot be opened directly on the phone.
5. On the iPhone, trust the developer entry under **Settings → General → VPN & Device Management** when prompted.
6. Enable **Settings → Privacy & Security → Developer Mode** if requested, restart the phone and confirm it. Available prompts can vary by iOS version.
7. Open **RoomPlan Test**.

For updates, use the same Apple account and bundle ID and install over the existing app. Avoid uninstalling while you still need saved scans. Keep exported files backed up. Free-account installations normally expire after 7 days; re-sign/reinstall or use Sideloadly's refresh feature.

If installation fails, save the Sideloadly error and record the phone model/iOS version. The build and packaging checks alone do not prove that a given phone accepts the IPA.

## 4. Make the first test scan

1. Use a small, well-lit room. Tap **Start scan** and allow camera access.
2. Move slowly around the room, following Apple's guidance. Include the walls, corners and a doorway or window.
3. Tap **Finish**. Wait for processing and the **Scan saved** message. The app requires at least one detected wall; this is a file-generation threshold, not a full-room quality guarantee.
4. Check the wall, door, window and object counts shown on the screen.
5. Tap **Share scan files**. Save both files to Files/OneDrive/iCloud Drive or another available share destination, then transfer them to Windows. There is no scan upload API in this app.
6. Put the matching `room.json` and `diagnostics.json` in one folder on Windows. Keep exports from different scans in separate folders.

Local storage on the phone:

```text
Documents/RoomPlanTest/<scan-uuid>/
  room.json
  diagnostics.json
```

`room.json` is written only after RoomPlan provides a processed room. Diagnostics are the completion marker. An incomplete attempt may contain no room file, or an uncommitted room file if final validation/writing failed. It is never listed as a completed scan.

**Share scan files** shares the latest successful scan and its matching diagnostics. **Share diagnostics** shares the latest attempt's log, including failures or cancellation. Starting another scan does not delete earlier folders. There is no scan-history browser in this test.

## 5. Validate the exported files on Windows

With Python 3 installed, run:

```powershell
py scripts/validate_scan.py "C:\path\to\exported-scan"
```

The validator checks JSON readability, the completed state and scan ID, the successful read-back event, wall geometry fields, and matching counts across both files. Also inspect the room's coverage on the phone: parsing JSON cannot establish geometric accuracy or a complete room.

Use this checklist for device acceptance:

- [ ] Codemagic's native tests and release build succeed and the IPA downloads.
- [ ] Sideloadly installs the app and it launches independently.
- [ ] A real room produces non-empty geometry and both exports pass validation on Windows.
- [ ] Cancel a new scan; the previous successful scan remains shareable.
- [ ] Deny camera permission; the app explains how to recover and diagnostics can be shared. Grant permission in Settings and retry.
- [ ] Make a second successful scan; its counts/files become the latest result.
- [ ] Close and reopen the app; the saved result is still shareable.
- [ ] Background the app during capture; it reports an interruption rather than success. Force-closing an attempt is recorded as interrupted on the next launch.

## Diagnostics and errors

Logs contain the scan ID, hardware model identifier, iOS/app versions, support and permission checks, attempt state, timestamped events, geometry counts, and available native errors. They do not contain photographs, Apple account credentials or raw camera footage. Room geometry still describes the scanned space; share test captures deliberately.

States include `checking`, `requesting_permission`, `scanning`, `processing`, `completed`, `cancelled`, `failed` and `interrupted`. Repeated Finish taps are ignored; processing has a 90-second timeout. Cancellation during processing ignores any late result.

If storage is full or inaccessible, the app may be unable to save even its diagnostic log; it reports that limitation on screen. If an app crashes before its last event is flushed, its log may end earlier than the failure.

## Development and checks

Use Flutter 3.35.4. The local preparation may leave an ignored SDK under `.tools/flutter`; it is not part of the deliverable or required by Codemagic. On Windows, Dart/Flutter tests run locally; building this iOS target requires the Codemagic Mac or another Mac with Xcode.

```powershell
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
py -m unittest discover -s scripts -p "test_*.py" -v
```

The `ios/RunnerTests` tests cover native storage persistence, cancellation, read-back failures, empty geometry, interrupted attempts, invalid paths and storage errors. Codemagic runs these on an iOS simulator; their synthetic fixtures are not real scans.

Channel: `be.aproxx.roomplan_device_test/scanner`.

| Method | Result |
| --- | --- |
| `getStatus` | Support message, permission state, latest successful summary and diagnostic availability |
| `startScan` | `{status: completed, scan: ...}` or `{status: cancelled}`; failures use `FlutterError` |
| `shareLatestResult` | Share sheet for the latest completed room and matching log |
| `shareDiagnostics` | Share sheet for the latest attempt's log |

Stable error codes include `unsupported_device`, `permission_denied`, `permission_restricted`, `busy`, `capture_failed`, `capture_interrupted`, `processing_timeout`, `empty_scan`, `file_write_failed`, `share_failed` and `scanner_unavailable`.

## Verification status

Local Flutter analysis and automated Flutter/Python checks are recorded in `VALIDATION.md`. The native Xcode checks, Codemagic IPA and real-device acceptance remain pending until the separate repository is connected and the workflow is run. No iPhone scan is included or fabricated.

## References

- [Apple RoomPlan](https://developer.apple.com/augmented-reality/roomplan/)
- [RoomCaptureView processed-result callback](https://developer.apple.com/documentation/roomplan/roomcaptureviewdelegate/captureview(didpresent:error:))
- [Codemagic unsigned builds](https://docs.codemagic.io/yaml-quick-start/first-signed-build/)
- [Codemagic Xcode 16.4 image](https://docs.codemagic.io/specs-macos/xcode-16-4/)
- [Sideloadly installation and refresh FAQ](https://sideloadly.io/faq)
