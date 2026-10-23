# Review of the teammate's 0.2.2 patch

Reviewed against the pre-existing `f703390` baseline and the ongoing 0.3.0 continuous-scan work. Source: `0001-scan-coverage-gate-0.2.2.patch`, SHA-256 `7ffe63e29f258ca9c2994d2aa90900f9a264a9f64df37df52ff401b973cd6da9`.

## Decision

**Reuse the focused scanner improvements; retain one continuous capture.** One Start scan launches RoomPlan, LiDAR and synchronized RGB/camera-data recording together. One Finish action saves their common package. No end-user training/check-pass control.

The patch applies cleanly to its old baseline, but overlaps and conflicts with current source/format/version changes. It was applied only in an ignored isolated review directory, never wholesale to the working app. Its **49 Python tests pass locally**, including the independent COLMAP reader. Neither its Swift changes nor the current guided scanner have been compiled on this Windows host; Codemagic and real-device checks remain required.

| Part | Decision |
| --- | --- |
| Pose-based motion filter, skip counters and slowdown feedback | Adapted into the current continuous writer. 60 degrees/second and 1 metre/second are initial heuristics, not proof of blur; tracking loss resets the baseline |
| Normalize node metadata to genuine JSON before checksums | Adapted, with binary-plist/type/checksum regression cases. Old packages remain readable; retained incomplete captures can be repackaged |
| Exclude window/opening/occluded wall areas from coverage requirements | Useful follow-up, but adapt it to stable surface IDs and multi-view guidance. Treat fully excluded surfaces as unassessed/not applicable, not observed |
| Original separate check-pass gate and automatic unlock after 180 seconds | Not adopted. Superseded by the single-scan flow and explicit save-with-warning action |
| Convex room clipping in desktop preparation | Deferred. Processing policy, not a requirement to record correct raw scan files; preserve raw depth/images |
| Claimed percentage thresholds and device readiness | Require calibration on representative phones/rooms. Two methods' percentages measure different things and should not be compared directly |

## Reproduced issues to address before further reuse

### 1. A recorded gate can disagree with the final room and still reach the trainer

Patch locations: `RoomScannerViewController.swift` (`startCheckPass`, `updateCoverage`); `CapturePackage.swift` (`validateCaptureReport`); `capture_pipeline.py` (`validate`, `prepare`).

The app freezes a list of wall percentages when the check pass starts. The list has no surface identifiers. RoomPlan can subsequently discover/change walls, yet the saved gate is not recomputed against the final live room. Desktop validation checks the supplied list's own threshold; independent recomputation merely becomes a report field. The existing trainer preflight does not enforce that field.

Reproduction on a synthetic four-wall fixture: a three-entry `[0.9, 0.8, 0.7]` record with gate `met` is accepted. Preparation recomputes `[0.3, 0, 0, 0]` and reports `insufficient`, but adapter preflight still passes. This reproduces a missing consistency check, not a claim that the supplied real scan contains forged metadata.

Use surface identifiers, reassess the final geometry after saved frames drain, and preserve a clear warning when readiness changes. The current continuous scanner uses identified surfaces, replays saved observations as geometry updates and assesses the latest saved live geometry at finish.

### 2. Fully excluded walls count as fully covered with no observations

Patch locations: `RoomCoverage.wallCoverage` and Python `wall_coverage`.

When no eligible wall cells remain after exclusions, both return 1. A synthetic room whose four walls are fully excluded as windows reports `[1, 1, 1, 1]` with **zero observed voxels**. This can satisfy the three-covered-wall minimum while providing no measured wall coverage.

Return a separate not-applicable/unassessed status, report the eligible denominator, and avoid counting such walls as observed. The useful idea is to avoid asking users to photograph physically hidden wall surfaces; excluding an area does not prove the window/furniture appearance was captured.

### 3. Clipping depth does not remove the corresponding photographic training content

Patch locations: `capture_pipeline.py` (`room_footprint`, `inside_room`, `prepare`).

The clipping changes seed points and depth-supervision masks, but source JPEGs are copied byte-for-byte. This was reproduced. The existing trainer's RGB loss still considers the full image; therefore the code does not prevent fitting visible content beyond windows/doorways. It is depth filtering, not complete scene/background masking.

A convex hull also does not represent concave rooms, and three detected wall fragments do not prove a closed outline. Before making this default, establish a valid room boundary and decide how RGB/alpha/depth masks should agree. Keep raw exports intact and make processing reversible/auditable.

## Further limits

- The voxel wall metric records depth hits, not the number/separation of photographic viewpoints. A wall seen from one place can score highly; global 20cm translation elsewhere does not fix that. The current guidance asks for separated views per sampled surface location and includes a floor estimate, while furniture quality still needs review.
- Wall coverage runs on the patch's main UI timer and scans up to 250,000 voxels across the walls. Profile it on the actual phone before reuse. Current guidance assessment runs on its own serial queue with bounded subsampled observations.
- An elapsed timeout is not evidence of improved coverage. Save-with-warning should be an explicit choice and preserve warnings in the exported/reopened result.

## Scope and status

The scanner remains separate from `3DViewerAproxx`. The agreed product work is capture, guidance and correct export of inputs needed by later processing. One all-frame splat trial was run locally as extra diagnostic evidence; no server, upload system or reconstruction integration was added to the actual app. Further splat development is parked. Current scanner validation and outstanding Codemagic/phone checks are recorded in [VALIDATION.md](../VALIDATION.md).
