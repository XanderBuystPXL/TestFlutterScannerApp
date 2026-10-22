# Commercial-use readiness

This records implemented engineering controls and remaining release decisions. It is not a legal certification, App Store approval or a blanket licence for third-party research tools. No new public licence is assigned to project-owned code by this document.

## Implemented in this standalone capture

- Public Apple RoomPlan/ARKit/AVFoundation/CoreImage/Foundation/CryptoKit APIs, no private APIs or external capture SDK. Apple SDK/distribution terms still apply.
- No reconstruction model/weights, downloaded inference, telemetry, ads, account system or automatic upload in capture code. Training uses sensor depth rather than a model whose weight licence needs separate approval.
- Explicit interior-photo/depth disclosure and recording-authorisation checkbox before capture; system camera permission; avoid people/private material guidance. Checkbox is an operational acknowledgement, not proof of every data subject's consent or a universal GDPR legal basis.
- Complete iOS file protection; app capture root excluded from device backup; UUID paths without property address/customer name. No Photos-library permission or writes.
- User-triggered sharing with clear unredacted-capture disclosure. Delete-all handles complete and partial captures; user confirms irreversible local deletion. Shared copies are outside the app's control.
- Relative frame times, not boot uptime; app-container metadata only. Privacy manifest declares FileTimestamp C617.1 and SystemBootTime 35F9.1. No tracking/automatic developer collection declared. Changes in integration must update these declarations.
- Flutter dependency licence screen; pinned SDK/lockfile and intake dependencies; build artifacts include inventories, notices and Flutter licence. No signing secrets in source.
- Safe bounded ZIP intake, integrity checks, explicit coordinate/split/normalization contracts, isolated holdout data, evidence-first acceptance. Hashes are not authentication.

## Before any commercial/customer product release

1. **Ownership/licences:** project owner approves rights to project code/assets. Retain full third-party notices for the exact shipped binary. Review the engine's generated NOTICES and privacy manifests in the compiled IPA. Refresh a vulnerability/dependency audit for the release. An allowlisted top-level licence is not an audit of transitive native libraries.
2. **Distribution:** use an organisation-approved Apple Developer/distribution route, current required Xcode/SDK and signing. The pinned Xcode 16.4 unsigned Sideloadly build is a development test, not a production distribution configuration. Do not market free personal provisioning as a customer rollout solution.
3. **Privacy owner/policy:** identify controller/processor, purpose/legal basis, transparent notice, retention period, access/deletion procedures and contacts. Interior photos/geometry may contain personal data even if no names are collected. Do not assume property-owner authorisation covers every person or item recorded.
4. **Data lifecycle:** choose approved sharing/storage destinations and access controls; define deletion for raw photos/depth, ZIPs, desktop intermediates, splats, backups and shared copies. Avoid public repositories/consumer sync for customer interiors. Device protection does not encrypt an exported ZIP or govern the receiving app.
5. **Processing service:** before adding upload/cloud GPU, approve vendors/DPAs, hosting region and any international transfers. Add authenticated tenant/project ownership, TLS, encryption at rest, limited access, retention/deletion and incident procedures. This test deliberately has no processing vendor or network backend.
6. **Publication:** establish permission and a redaction/masking workflow for private text/faces before training/publication. Cropping thumbnails alone does not remove sensitive content from a splat. Keep unredacted source access limited.
7. **Quality claims:** complete real-device acceptance and first target-viewer reconstruction. Agree customer accuracy/completeness expectations; RoomPlan dimensions and a successful training run are not professional measurement certification.

## Optional existing reconstruction PoC

The adapter invokes existing research code without copying/modifying it. It skips predicted-depth inference/weights. gsplat's upstream licence is Apache-2.0, but the **exact** GPU environment (including CUDA/PyTorch, COLMAP binaries, OpenCV and bundled native components) still needs a deployment-specific licence/notices review. The capture app does not distribute these tools. No noncommercial Gaussian implementation or pretrained weight is added here. Do not treat the wrapper as clearance for every existing research dependency or later viewer asset.

## Primary sources checked

- [Apple RoomPlan public APIs and exports](https://developer.apple.com/videos/play/wwdc2023/10192/)
- [Apple required API reason definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)
- [Apple App Review privacy rules](https://developer.apple.com/app-store/review/guidelines/#privacy)
- [GDPR, especially Articles 5, 6, 13, 17, 28, 32 and Chapter V](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32016R0679)
- [Flutter licence](https://github.com/flutter/flutter/blob/3.35.4/LICENSE)
- [gsplat upstream licence](https://github.com/nerfstudio-project/gsplat/blob/main/LICENSE)

Reviewed 22 October 2026. Recheck requirements and exact versions before release. Organisation/legal decisions remain with the project/customer; code cannot establish them automatically.
