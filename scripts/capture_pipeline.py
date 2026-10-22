"""Versioned iPhone intake, metric sensor initialization and portable splat inputs.

No model download, cloud upload, SfM or training occurs in this tool.
"""
import argparse
import hashlib
import io
import json
import math
import re
from pathlib import Path, PurePosixPath
import stat
import struct
import tempfile
import zipfile

import numpy as np
from PIL import Image, ImageDraw

BASIS = np.diag([1., -1., -1., 1.])
MAX_BYTES = 4 * 1024**3
MAX_FILE_BYTES = 64 * 1024**2
MAX_FILES = 6000
Image.MAX_IMAGE_PIXELS = 24_000_000


def require(condition, message):
    if not condition:
        raise ValueError(message)


def safe_path(name):
    require(isinstance(name, str) and name and "\\" not in name and ":" not in name,
            f"Unsafe package path: {name!r}")
    require(not any(ord(c) < 32 for c in name), "Control characters in package path.")
    p = PurePosixPath(name)
    require(not p.is_absolute() and all(x not in {"", ".", ".."} for x in name.split("/")),
            f"Unsafe package path: {name!r}")
    return p.as_posix()


def json_bytes(data):
    def reject(value):
        raise ValueError(f"Non-finite JSON number: {value}")
    return json.loads(data, parse_constant=reject)


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, allow_nan=False) + "\n", encoding="utf-8")


class Package:
    """Read without extracting arbitrary archives. All reads have explicit limits."""
    def __init__(self, source):
        self.source = Path(source)
        self.zip = None
        if self.source.is_dir():
            require(not self.source.is_symlink(), "Symlink capture root is not allowed.")
            paths = list(self.source.rglob("*"))
            require(not any(p.is_symlink() for p in paths), "Symlink capture paths are not allowed.")
            self.entries = {safe_path(p.relative_to(self.source).as_posix()): p for p in paths if p.is_file()}
            self.sizes = {n: p.stat().st_size for n, p in self.entries.items()}
        else:
            self.zip = zipfile.ZipFile(self.source)
            try:
                items = self.zip.infolist()
                require(not any(i.is_dir() for i in items), "Expected payload files only, no directory entries.")
                names = [safe_path(i.filename) for i in items]
                require(len(set(n.casefold() for n in names)) == len(names), "Duplicate/case-colliding ZIP paths.")
                require(not any(stat.S_ISLNK(i.external_attr >> 16) or i.flag_bits & 1 for i in items),
                        "Symlinks and encrypted entries are not accepted.")
                self.entries = dict(zip(names, items))
                self.sizes = {n: i.file_size for n, i in self.entries.items()}
                require(all(i.compress_type in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED} and
                            i.file_size <= max(1, i.compress_size) * 200 for i in items), "Unsafe ZIP compression.")
            except BaseException:
                self.zip.close()
                raise
        try:
            require(len(self.entries) <= MAX_FILES, "Too many files in capture.")
            require(sum(self.sizes.values()) < MAX_BYTES, "Capture exceeds 4 GiB intake limit.")
            require(all(0 <= s <= MAX_FILE_BYTES for s in self.sizes.values()), "Capture file exceeds 64 MiB limit.")
            require(len({n.casefold() for n in self.entries}) == len(self.entries), "Case-colliding payload paths.")
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.zip:
            self.zip.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def read(self, name):
        name = safe_path(name)
        require(name in self.entries, f"Missing payload: {name}")
        with (self.zip.open(self.entries[name]) if self.zip else self.entries[name].open("rb")) as stream:
            data = stream.read(MAX_FILE_BYTES + 1)
        require(len(data) == self.sizes[name] <= MAX_FILE_BYTES, f"Invalid file size: {name}")
        return data

    def obj(self, name):
        return json_bytes(self.read(name))

    def lines(self, name):
        return [json_bytes(line) for line in self.read(name).splitlines() if line.strip()]


def matrix(value, shape, label):
    m = np.asarray(value, dtype=np.float64)
    require(m.shape == shape and np.isfinite(m).all(), f"Invalid {label} matrix.")
    return m


def calibration(value, width, height):
    K = matrix(value, (3, 3), "intrinsics")
    require(width > 0 and height > 0 and width * height <= Image.MAX_IMAGE_PIXELS, "Invalid image dimensions.")
    require(K[0, 0] > 0 and K[1, 1] > 0 and 0 <= K[0, 2] < width and 0 <= K[1, 2] < height and
            np.allclose(K[2], [0, 0, 1]) and abs(K[0, 1]) < 1e-5 and abs(K[1, 0]) < 1e-5,
            "Invalid pinhole calibration.")
    return K


def pose(value):
    T = matrix(value, (4, 4), "camera pose")
    require(np.allclose(T[3], [0, 0, 0, 1], atol=1e-5) and
            np.allclose(T[:3, :3].T @ T[:3, :3], np.eye(3), atol=1e-4) and
            abs(np.linalg.det(T[:3, :3]) - 1) < 1e-4, "Camera pose is not a rigid right-handed transform.")
    return T


def depth_arrays(package, frame):
    d, c = frame["depth"], frame["confidence"]
    shape = (d["height"], d["width"])
    depth = np.frombuffer(package.read(d["path"]), dtype="<f4").reshape(shape)
    confidence = np.frombuffer(package.read(c["path"]), dtype=np.uint8).reshape(shape)
    return depth, confidence


def reliable_mask(depth, confidence):
    valid = np.isfinite(depth) & (depth > .10) & (depth < 12.) & (confidence >= 1)
    safe = np.where(valid, depth, 0.)
    # Reject both sides of large discontinuities, not just the second pixel.
    dx = np.abs(np.diff(safe, axis=1)) > .06 * np.maximum(safe[:, 1:], .1)
    dy = np.abs(np.diff(safe, axis=0)) > .06 * np.maximum(safe[1:], .1)
    valid[:, :-1] &= ~dx
    valid[:, 1:] &= ~dx
    valid[:-1] &= ~dy
    valid[1:] &= ~dy
    return valid


def backproject(depth, K, cv_world):
    y, x = np.indices(depth.shape)
    rays = np.stack([x, y, np.ones_like(x)], axis=-1) @ np.linalg.inv(K).T
    camera = rays * depth[..., None]
    return camera @ cv_world[:3, :3].T + cv_world[:3, 3]


def validate(package):
    hashes = package.obj("checksums.json")
    require(hashes.get("algorithm") == "sha256", "SHA-256 checksums required.")
    expected = hashes["files"]
    require(set(expected) == set(package.entries) - {"checksums.json"}, "Checksum inventory differs from payload.")
    for name, item in expected.items():
        data = package.read(name)
        require(len(data) == item["bytes"] and hashlib.sha256(data).hexdigest() == item["sha256"],
                f"Checksum mismatch: {name}")
    m = package.obj("manifest.json")
    require(m.get("format") == "aproxx.iphone-scan" and m.get("schema_version") == 1, "Unsupported capture format.")
    import uuid
    uuid.UUID(m["scan_id"])
    require(m["scan_id"] == m["room_id"], "Single-room capture ID differs.")
    cs = m["coordinate_system"]
    required = {"coordinate_space_id": m["scan_id"], "units": "metres", "world": "arkit_right_handed_y_up",
                "camera": "arkit_right_up_back", "matrix_layout": "rows_acting_on_column_vectors",
                "image_axes": "right_down", "image_orientation": "native_sensor_unrotated_unmirrored",
                "world_alignment": "gravity"}
    require(all(cs.get(k) == v for k, v in required.items()) and np.array_equal(cs["cv_camera_basis"], BASIS),
            "Unsupported coordinates/orientation.")
    files = {"frames": "frames.jsonl", "events": "events.jsonl", "room": "room.json",
             "usdz": "roomplan/room.usdz", "node_map": "roomplan/node-map.json", "live_room": "roomplan/live-room.json", "checksums": "checksums.json"}
    require(m["files"] == files, "Unexpected payload layout.")
    diag, room = package.obj("diagnostics.json"), package.obj("room.json")
    require(diag["state"] == "completed" and diag["scanId"] == m["scan_id"], "Capture was not committed.")
    require(diag["capture"] == m["capture"], "Diagnostics/capture report differ.")
    require(len(room.get("walls", [])) > 0, "Room geometry is empty.")
    for key, count in diag["counts"].items():
        require(len(room.get(key, [])) == count, f"Room count differs: {key}")
    require(all("transform" in wall and "dimensions" in wall for wall in room["walls"]), "Missing wall geometry.")
    require(package.read(files["usdz"])[:4] == b"PK\x03\x04", "USDZ is not a ZIP container.")
    require(isinstance(package.obj(files["node_map"]), (dict, list)), "Invalid RoomPlan node map.")
    require(len(package.obj(files["live_room"]).get("walls", [])) > 0, "Missing live RoomPlan alignment evidence.")
    events = package.lines(files["events"])
    require(events and events == diag["events"] and events[-1]["name"] == "room_written_and_read_back", "Event log differs.")
    frames = package.lines(files["frames"])
    require(30 <= len(frames) <= 1800, "Expected 30..1800 synchronized capture frames.")
    seen, assets, last_time, validation_started = set(), set(), -math.inf, False
    usable = {"train": 0, "validation": 0}
    for f in frames:
        require(isinstance(f["frame_id"], str) and re.fullmatch(r"frame-\d{6}", f["frame_id"], re.ASCII), "Invalid frame ID.")
        require(f["frame_id"] not in seen, "Duplicate frame ID.")
        seen.add(f["frame_id"])
        require(f["room_id"] == f["coordinate_space_id"] == m["scan_id"], "Mixed coordinate spaces.")
        require(f["role"] in usable and f["segment_id"] == f["role"], "Invalid capture role.")
        validation_started |= f["role"] == "validation"
        require(not validation_started or f["role"] == "validation", "Training resumes after check pass.")
        t = f["timestamp_seconds"]
        require(isinstance(t, (int, float)) and math.isfinite(t) and t > last_time, "Frame timestamps must increase.")
        last_time = t
        require(f["tracking_state"] == "normal" and f["image_transform"] == "identity", "Unusable tracking/orientation.")
        w, h = f["rgb_size_px"]
        K = calibration(f["intrinsics"], w, h)
        pose(f["camera_to_world"])
        with Image.open(io.BytesIO(package.read(f["rgb_path"]))) as image:
            require(image.format == "JPEG" and image.size == (w, h), "RGB dimensions/encoding differ.")
            require(image.getexif().get(274, 1) == 1, "Unexpected JPEG orientation tag.")
            image.load()
        d, c = f["depth"], f["confidence"]
        require(d["encoding"] == "float32-le" and d["units"] == "metres" and d["source"] == "sceneDepth" and
                d["convention"] == "positive_camera_z" and d["rgb_mapping"] == "scaled_intrinsics_no_crop" and
                d["timestamp_seconds"] == t, "Depth provenance/synchronization differs.")
        require(c["encoding"] == "uint8" and (c["width"], c["height"]) == (d["width"], d["height"]), "Confidence dimensions differ.")
        dK = calibration(d["intrinsics"], d["width"], d["height"])
        expected_K = K.copy()
        expected_K[0] *= d["width"] / w
        expected_K[1] *= d["height"] / h
        require(np.allclose(dK, expected_K, rtol=1e-5, atol=1e-4), "Depth/RGB rays differ.")
        paths = [f["rgb_path"], d["path"], c["path"]]
        require(paths == [f"rgb/{f['frame_id']}.jpg", f"depth/{f['frame_id']}.f32", f"confidence/{f['frame_id']}.u8"],
                "Frame asset names differ from the canonical layout.")
        require(not assets.intersection(paths) and len(set(paths)) == 3, "Reused RGB/depth/confidence asset.")
        assets.update(paths)
        depth, confidence = depth_arrays(package, f)
        require(np.isin(confidence, [0, 1, 2]).all(), "Invalid confidence label.")
        require(reliable_mask(depth, confidence).mean() >= .02, "Frame has too little usable LiDAR depth.")
        usable[f["role"]] += 1
    require(usable["train"] >= 20 and usable["validation"] >= 10, "Need 20 training and 10 check frames.")
    report = m["capture"]
    require(report["train_frames"] == usable["train"] and report["validation_frames"] == usable["validation"] and
            report["saved_frames"] == len(frames), "Frame counts differ from manifest.")
    require(report["first_timestamp_seconds"] == frames[0]["timestamp_seconds"] and
            report["last_timestamp_seconds"] == frames[-1]["timestamp_seconds"], "Capture time bounds differ.")
    centers = np.array([f["camera_to_world"] for f in frames if f["role"] == "train"])[:, :3, 3]
    span = float(np.linalg.norm(np.ptp(centers, axis=0)))
    require(span >= .20 and abs(span - report["training_camera_span_metres"]) < 1e-4, "Training camera movement differs/is too small.")
    require(assets | set(files.values()) | {"manifest.json", "diagnostics.json"} == set(package.entries), "Unexpected/unreferenced assets.")
    return m, frames


def room_matrix(value):
    a = np.asarray(value, dtype=np.float64)
    # Apple's SIMD Codable uses 16 values in column order, unlike frame JSON rows.
    if a.shape == (16,):
        a = a.reshape((4, 4), order="F")
    return pose(a)


def room_alignment(live, processed):
    """Match wall identities, never guess how an undocumented referenceOriginTransform applies."""
    by_id = {w.get("identifier"): w for w in live["walls"] if w.get("identifier")}
    pairs = [(room_matrix(by_id[w["identifier"]]["transform"]), room_matrix(w["transform"]))
             for w in processed["walls"] if w.get("identifier") in by_id]
    if len(pairs) < 3:
        return {"status": "insufficient_matching_walls", "matched_walls": len(pairs),
                "processed_to_capture_world": None, "physical_review": "required"}
    rotations = np.stack([a[:3, :3] @ b[:3, :3].T for a, b in pairs])
    U, _, V = np.linalg.svd(np.mean(rotations, axis=0))
    R = U @ np.diag([1, 1, np.linalg.det(U @ V)]) @ V
    t = np.median([a[:3, 3]-R @ b[:3, 3] for a, b in pairs], axis=0)
    distances = [float(np.linalg.norm(a[:3, 3] - (R @ b[:3, 3]+t))) for a, b in pairs]
    angles = [float(np.degrees(np.arccos(np.clip((np.trace(a[:3, :3].T @ R @ b[:3, :3])-1)/2, -1, 1)))) for a, b in pairs]
    good = np.median(distances) <= .10 and max(distances) <= .30 and np.median(angles) <= 5
    T = np.eye(4)
    T[:3, :3], T[:3, 3] = R, t
    return {"status": "matched_geometry_requires_physical_review" if good else "geometry_disagreement",
            "matched_walls": len(pairs), "center_residual_metres": distances, "rotation_residual_degrees": angles,
            "processed_to_capture_world": T.tolist() if good else None, "physical_review": "required",
            "encoded_reference_origin_preserved_not_assumed": processed.get("referenceOriginTransform")}


def quaternion(R):
    # Stable eigendecomposition, scalar first, rotation is world-to-CV-camera.
    M = np.array([[R[0, 0]-R[1, 1]-R[2, 2], R[1, 0]+R[0, 1], R[2, 0]+R[0, 2], R[2, 1]-R[1, 2]],
                  [R[1, 0]+R[0, 1], R[1, 1]-R[0, 0]-R[2, 2], R[2, 1]+R[1, 2], R[0, 2]-R[2, 0]],
                  [R[2, 0]+R[0, 2], R[2, 1]+R[1, 2], R[2, 2]-R[0, 0]-R[1, 1], R[1, 0]-R[0, 1]],
                  [R[2, 1]-R[1, 2], R[0, 2]-R[2, 0], R[1, 0]-R[0, 1], R.trace()]]) / 3
    _, vectors = np.linalg.eigh(M)
    q = vectors[:, -1][[3, 0, 1, 2]]
    return q if q[0] >= 0 else -q


def colmap_model(root, frames, points, colors):
    """Interchange only: ARKit poses/sensor points, no fabricated SfM observations."""
    folder = root / "sparse" / "0"
    folder.mkdir(parents=True)
    with (folder / "cameras.bin").open("wb") as cams, (folder / "images.bin").open("wb") as images:
        cams.write(struct.pack("<Q", len(frames)))
        images.write(struct.pack("<Q", len(frames)))
        for index, f in enumerate(frames, 1):
            K = np.asarray(f["intrinsics"])
            w, h = f["rgb_size_px"]
            cams.write(struct.pack("<iiQQdddd", index, 1, w, h, K[0, 0], K[1, 1], K[0, 2], K[1, 2]))
            view = np.linalg.inv(np.asarray(f["camera_to_world"]) @ BASIS)
            images.write(struct.pack("<i7di", index, *quaternion(view[:3, :3]), *view[:3, 3], index))
            images.write((Path(f["rgb_path"]).name + "\0").encode("utf-8"))
            images.write(struct.pack("<Q", 0))
    with (folder / "points3D.bin").open("wb") as stream:
        stream.write(struct.pack("<Q", len(points)))
        for index, (p, c) in enumerate(zip(points, colors), 1):
            stream.write(struct.pack("<QdddBBBdQ", index, *p, *c, 0., 0))


def prepare(source, output):
    output = Path(output).resolve()
    require(not output.exists(), "Output already exists; use a new dataset folder.")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Work in a sibling staging folder; a failed conversion cannot look complete.
    with Package(source) as package, tempfile.TemporaryDirectory(prefix=".capture-", dir=output.parent) as tmp:
        manifest, frames = validate(package)
        root = Path(tmp) / "dataset"
        root.mkdir()
        for d in ["images", "sensor_depth", "holdout_depth", "geometry", "evidence"]:
            (root / d).mkdir()
        for name in ["manifest.json", "checksums.json", "diagnostics.json", "frames.jsonl", "events.jsonl"]:
            (root / "evidence" / name).write_bytes(package.read(name))
        for name, dest in [("room.json", "room.json"), ("roomplan/room.usdz", "room.usdz"), ("roomplan/node-map.json", "node-map.json"), ("roomplan/live-room.json", "live-room.json")]:
            (root / "geometry" / dest).write_bytes(package.read(name))
        alignment = room_alignment(package.obj("roomplan/live-room.json"), package.obj("room.json"))
        write_json(root / "geometry" / "alignment.json", alignment)
        centers = np.array([f["camera_to_world"] for f in frames if f["role"] == "train"])[:, :3, 3]
        origin = np.median(centers, axis=0)
        radius = float(np.percentile(np.linalg.norm(centers - origin, axis=1), 90))
        require(radius > 1e-4, "Unstable training normalization.")
        normalization = {"origin": origin.tolist(), "scale": 1 / radius, "units": "arbitrary"}
        points, colors, rows, depth_views, transforms = [], [], [], [], []
        for index, f in enumerate(frames):
            name = Path(f["rgb_path"]).name
            (root / "images" / name).write_bytes(package.read(f["rgb_path"]))
            depth, confidence = depth_arrays(package, f)
            mask = reliable_mask(depth, confidence)
            K = np.asarray(f["intrinsics"])
            dK = np.asarray(f["depth"]["intrinsics"])
            ar_world = np.asarray(f["camera_to_world"])
            cv_world = ar_world @ BASIS
            row = {"name": name, "role": f["role"], "K": K.tolist(), "size": f["rgb_size_px"],
                   "camera_to_world_cv_metres": cv_world.tolist(), "timestamp_seconds": f["timestamp_seconds"]}
            rows.append(row)
            folder = "sensor_depth" if f["role"] == "train" else "holdout_depth"
            filename = f"view-{index:04d}.npz"
            # DepthProvider expects the same normalization as CaptureScene.
            np.savez_compressed(root / folder / filename, depth=np.where(mask, depth / radius, 0).astype(np.float32),
                                mask=mask, confidence=confidence, K=dK.astype(np.float32))
            if f["role"] == "train":
                depth_views.append({"index": index, "image": name, "file": filename})
                grid = np.zeros_like(mask)
                grid[::4, ::4] = True
                grid &= mask
                world_points = backproject(np.where(mask, depth, 0), dK, cv_world)
                with Image.open(io.BytesIO(package.read(f["rgb_path"]))) as im:
                    rgb = np.array(im.convert("RGB").resize(depth.shape[::-1], Image.Resampling.BOX))
                points.append(world_points[grid])
                colors.append(rgb[grid])
            transforms.append({"file_path": "images/" + name, "transform_matrix": ar_world.tolist(),
                               "fl_x": float(K[0, 0]), "fl_y": float(K[1, 1]), "cx": float(K[0, 2]),
                               "cy": float(K[1, 2]), "w": f["rgb_size_px"][0], "h": f["rgb_size_px"][1]})
        xyz, rgb = np.concatenate(points), np.concatenate(colors)
        # Voxel downsample in metric capture space, train-only and deterministic.
        _, unique = np.unique(np.floor(xyz / .03).astype(np.int64), axis=0, return_index=True)
        unique = unique[:200_000]
        xyz, rgb = xyz[unique], rgb[unique]
        require(len(xyz) >= 100, "Insufficient training-only depth initialization (need 100 points).")
        np.savez_compressed(root / "points.npz", points=((xyz-origin)/radius).astype(np.float32), colors=rgb)
        # Legacy trainer appends this file; seeds are already in points.npz so do not duplicate.
        np.savez_compressed(root / "sensor_depth" / "initialization.npz", points=np.empty((0, 3), np.float32), colors=np.empty((0, 3), np.uint8))
        write_json(root / "sensor_depth" / "report.json", {"schema_version": 1, "kind": "sensor",
                   "units": "normalized arbitrary scene units", "depth_convention": "positive camera-z",
                   "normalization": normalization, "scene_names": [r["name"] for r in rows], "training_only": True,
                   "views": depth_views, "source": "ARFrame.sceneDepth", "point_samples": len(xyz)})
        write_json(root / "pipeline.json", {"schema_version": 1, "source_scan_id": manifest["scan_id"],
                   "source_checksums_sha256": hashlib.sha256(package.read("checksums.json")).hexdigest(),
                   "normalization": normalization, "frames": rows, "initialization": "training_only_sensor_depth",
                   "validation_protocol": manifest["validation_protocol"], "alignment_acceptance": "pending_real_device_review"})
        train_names = ["images/" + r["name"] for r in rows if r["role"] == "train"]
        val_names = ["images/" + r["name"] for r in rows if r["role"] == "validation"]
        write_json(root / "transforms.json", {"camera_model": "OPENCV", "orientation_override": "none",
                   "applied_scale": 1., "frames": transforms, "train_filenames": train_names,
                   "val_filenames": val_names, "test_filenames": val_names})
        colmap_model(root, frames, xyz, rgb)
        write_ply(root / "preview.ply", xyz, rgb)
        camera_positions = np.array([f["camera_to_world"] for f in frames])[:, :3, 3]
        camera_colors = np.array([[0, 180, 255] if f["role"] == "train" else [255, 180, 0] for f in frames], dtype=np.uint8)
        write_ply(root / "camera-path.ply", camera_positions, camera_colors)
        if alignment["processed_to_capture_world"] is not None:
            T = np.array(alignment["processed_to_capture_world"])
            walls = []
            for wall in package.obj("room.json")["walls"]:
                width, height = wall["dimensions"][:2]
                x, y = np.meshgrid(np.linspace(-width/2, width/2, 30), np.linspace(-height/2, height/2, 20))
                local = np.stack([x.ravel(), y.ravel(), np.zeros(x.size), np.ones(x.size)], -1)
                walls.append((local @ (T @ room_matrix(wall["transform"])).T)[:, :3])
            wall_points = np.concatenate(walls)
            write_ply(root / "room-walls.ply", wall_points, np.tile(np.array([[255, 80, 100]], np.uint8), (len(wall_points), 1)))
        review_images(package, frames, root)
        write_json(root / "intake-report.json", {"status": "structural_checks_passed",
                   "train_frames": len(train_names), "check_frames": len(val_names), "train_seed_points": len(xyz),
                   "not_proven": ["physical RGB-depth alignment", "tracking drift and room alignment", "room coverage", "reconstruction quality"]})
        # Fingerprints bind adapter input, images and depth to this conversion.
        inventory = {}
        for file in sorted(root.rglob("*")):
            if file.is_file():
                inventory[file.relative_to(root).as_posix()] = hashlib.sha256(file.read_bytes()).hexdigest()
        write_json(root / "dataset-checksums.json", inventory)
        root.rename(output)
    return output


def verify_dataset(root):
    root = Path(root)
    require(not root.is_symlink() and not any(p.is_symlink() for p in root.rglob("*")), "Dataset symlinks are not allowed.")
    hashes = json_bytes((root / "dataset-checksums.json").read_bytes())
    for name, digest in hashes.items():
        path = root / safe_path(name)
        require(not path.is_symlink() and path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest,
                f"Prepared dataset changed: {name}")
    require(set(hashes) == {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()} - {"dataset-checksums.json"},
            "Prepared dataset inventory changed.")
    return json_bytes((root / "pipeline.json").read_bytes())


def write_ply(path, points, colors):
    with Path(path).open("wb") as stream:
        stream.write(("ply\nformat binary_little_endian 1.0\nelement vertex " + str(len(points)) +
                      "\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n").encode())
        packed = np.empty(len(points), dtype=[("p", "<f4", 3), ("c", "u1", 3)])
        packed["p"], packed["c"] = points, colors
        stream.write(packed.tobytes())


def review_images(package, frames, root):
    picks = np.unique(np.linspace(0, len(frames)-1, min(12, len(frames))).astype(int))
    sheet = Image.new("RGB", (960, math.ceil(len(picks)/3)*220), "#151b25")
    draw = ImageDraw.Draw(sheet)
    for slot, index in enumerate(picks):
        f = frames[index]
        depth, confidence = depth_arrays(package, f)
        with Image.open(io.BytesIO(package.read(f["rgb_path"]))) as image:
            image = image.convert("RGB")
            image.thumbnail((310, 175))
            x, y = (slot % 3)*320, (slot//3)*220
            sheet.paste(image, (x, y))
        draw.text((x+5, y+180), f'{index}: {f["role"]}; depth {reliable_mask(depth, confidence).mean():.0%}', fill="white")
    sheet.save(root / "contact-sheet.jpg", quality=90)
    # RGB/depth overlay is for physical edge-alignment review, never an automatic proof.
    for role in ["train", "validation"]:
        f = next(f for f in frames if f["role"] == role)
        depth, confidence = depth_arrays(package, f)
        valid = reliable_mask(depth, confidence)
        display = np.clip(np.nan_to_num(depth, nan=0., posinf=0.) / 8 * 255, 0, 255).astype(np.uint8)
        heat = np.stack([display, 255-display, np.zeros_like(display)], -1)
        heat[~valid] = 0
        with Image.open(io.BytesIO(package.read(f["rgb_path"]))) as im:
            rgb = im.convert("RGB").resize(depth.shape[::-1], Image.Resampling.BOX)
        Image.blend(rgb, Image.fromarray(heat), .4).resize((768, 576)).save(root / f"alignment-{role}.png")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("validate")
    check.add_argument("capture")
    convert = sub.add_parser("prepare")
    convert.add_argument("capture")
    convert.add_argument("output")
    args = parser.parse_args()
    try:
        if args.command == "validate":
            with Package(args.capture) as p:
                m, frames = validate(p)
            print(f"PASS: {m['scan_id']}, {len(frames)} synchronized frames. Physical alignment/reconstruction still require review.")
        else:
            print(f"Prepared: {prepare(args.capture, args.output)}")
    except (ValueError, KeyError, TypeError, OverflowError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Capture rejected: {error}\n")


if __name__ == "__main__":
    main()
