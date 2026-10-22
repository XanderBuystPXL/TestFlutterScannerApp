# Capture format 1

`manifest.format = aproxx.iphone-scan`, `schema_version = 1`. One UUID/coordinate space per attempt. New attempts never reuse or silently merge old frames.

```text
Documents/RoomPlanTest/<UUID>/
  manifest.json
  frames.jsonl
  events.jsonl
  checksums.json
  diagnostics.json
  room.json
  rgb/frame-000001.jpg
  depth/frame-000001.f32
  confidence/frame-000001.u8
  roomplan/room.usdz
  roomplan/node-map.json
  roomplan/live-room.json
  scan-<UUID>.zip
```

The ZIP contains every payload except itself. `checksums.json` maps every other payload path to byte size/SHA-256; it excludes itself. Native ZIP32 uses stored entries, CRC32, UTF-8 names, <4 GiB total. Desktop intake additionally bounds entries/files/total bytes and rejects unsafe paths, symlinks, duplicates, unreferenced assets and excessive decompression.

## Frames

Each JSONL row holds frame/room/coordinate/segment IDs, `role` (`train` or `validation`), relative timestamp, image path/size, 3×3 intrinsics, 4×4 `camera_to_world`, tracking state, image transform, depth and confidence descriptors.

RGB/calibration/pose/depth/confidence come from the **same ARFrame**. The shared ARSession is polled at 20Hz; at most three samples/second are admitted. A two-slot serial background writer bounds retained pixel buffers. ARFrame objects are not retained on the writer queue. Backpressure, limited tracking and missing depth are counted. Frame numbers can have gaps. Previous-frame depth is never substituted.

Times are relative seconds from the first observed ARFrame in that attempt, not device uptime. UTC event/completion times are separate. RGB/depth timestamps match. This is ARKit frame association, not a claim about simultaneous physical sensor exposures or absence of internal filtering.

JPEGs preserve the original unrotated/unmirrored sensor raster, sRGB, quality 0.95, without crop, resize or portrait EXIF transform. Dimensions match ARCamera.imageResolution. Intrinsics refer to that raster regardless of UI orientation.

Depth is raw `sceneDepth`, not smoothed depth: `width*height` IEEE754 float32 little-endian, row-major, metres, positive camera-Z (distance to camera plane, not Euclidean range). Invalid/non-finite/zero pixels are not measurements. Confidence is row-major UInt8: 0 low, 1 medium, 2 high. Pixel-buffer row padding is stripped.

Depth K scales RGB K rows by depth/RGB width and height. No undocumented crop is assumed. Desktop masks invalid/out-of-range/low-confidence samples and depth discontinuities. The 0.1–12m engineering filter is not a promise of LiDAR accuracy over that range. Physical depth/RGB alignment remains an acceptance check.

## Coordinates and RoomPlan

Frame matrices contain explicit **rows acting on column vectors**. ARKit world is right-handed, gravity-aligned +Y up. Native camera axes are right/up/back, looking toward −Z. CV axes are right/down/forward:

```text
T_cv_to_capture = T_arkit_to_capture × diag(1,-1,-1,1)
p_cv = inverse(K) × [u,v,1] × depth_metres
p_capture = T_cv_to_capture × [p_cv,1]
```

Apple's complete encoded room remains unchanged. Its SIMD transforms can be flat column-major 16-element arrays, unlike frame matrices. The importer handles both encodings explicitly.

`live-room.json` preserves the last live room before Finish. Postprocessing may change the origin. The importer fits processed-to-live correction from ≥3 matching wall IDs and reports center/axis residuals. It preserves `referenceOriginTransform` without inventing semantics for an undocumented encoded field. It emits no correction when evidence is insufficient/inconsistent. A numerical fit still needs physical comparison to the metric sensor cloud. Never add a guessed second origin correction.

## Completion and splits

Completion requires processed walls, JSON validation/exact byte read-back, drained writer, ≥20 train/≥10 check frames and ≥0.2m train camera span. These are sanity minima, not coverage proof. USDZ/node-map export, checksums and ZIP must succeed before success returns. A missing ZIP after a packaging crash is recovered as interrupted. Partial attempts do not replace successful scans.

The explicit check-pass RGB/depth never enters fitting/initialization through this adapter; normalization uses training cameras only. ARKit/RoomPlan still map the whole capture, including the check route. Label evaluation as held-out appearance/depth with shared mapping, not independent localization.

Diagnostics contain build/device versions, support/permission, state, UTC events, errors, result counts and drop counts. Application code records no account credentials, GPS, device name, serial or advertising identifier. Hardware identifier describes a model class. Interior geometry and images remain sensitive.

Hashes prove byte integrity, not sender identity or physical accuracy. Dataset checksums bind converted files/provenance. Upload authentication, resumable delivery, tenant/project association and multiroom capture are separate integration work.
