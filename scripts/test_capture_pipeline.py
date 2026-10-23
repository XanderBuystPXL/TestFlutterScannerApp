"""Synthetic fixtures test the contract, never count as real-device acceptance."""
import hashlib
import io
import importlib.util
import json
import plistlib
from pathlib import Path
import struct
import tempfile
import sys
import unittest
from unittest.mock import patch
import uuid
import zipfile

import numpy as np
from PIL import Image

from capture_pipeline import (BASIS, Package, backproject, prepare, quaternion, room_alignment, safe_path,
                              validate, verify_dataset, write_json)
from capture_scene import scene_arrays
from run_poc import preflight, no_holdout_evaluation, main as run_poc_main


def fixture(root):
    scan = str(uuid.uuid4()).upper()
    for d in ["rgb", "depth", "confidence", "roomplan"]:
        (root / d).mkdir(parents=True)
    K = np.array([[50., 0, 32], [0, 50, 24], [0, 0, 1]])
    image = io.BytesIO()
    Image.new("RGB", (64, 48), (100, 140, 180)).save(image, format="JPEG")
    frames = []
    for i in range(30):
        name = f"frame-{i+1:06d}"
        T = np.eye(4)
        T[0, 3] = i*.03 if i < 20 else 100+(i-20)*.03
        role = "train" if i < 20 else "validation"
        f = {"frame_id": name, "room_id": scan, "coordinate_space_id": scan, "segment_id": role,
             "role": role, "timestamp_seconds": 100.+i/3, "rgb_path": f"rgb/{name}.jpg",
             "rgb_size_px": [64, 48], "intrinsics": K.tolist(), "camera_to_world": T.tolist(),
             "tracking_state": "normal", "image_transform": "identity",
             "depth": {"path": f"depth/{name}.f32", "width": 32, "height": 24, "encoding": "float32-le",
                       "units": "metres", "convention": "positive_camera_z", "source": "sceneDepth",
                       "timestamp_seconds": 100.+i/3, "intrinsics": (np.diag([.5, .5, 1]) @ K).tolist(),
                       "rgb_mapping": "scaled_intrinsics_no_crop"},
             "confidence": {"path": f"confidence/{name}.u8", "width": 32, "height": 24, "encoding": "uint8"}}
        (root / f["rgb_path"]).write_bytes(image.getvalue())
        (root / f["depth"]["path"]).write_bytes(np.full((24, 32), 2, dtype="<f4").tobytes())
        (root / f["confidence"]["path"]).write_bytes(np.full((24, 32), 2, dtype=np.uint8).tobytes())
        frames.append(f)
    (root / "frames.jsonl").write_text("".join(json.dumps(f)+"\n" for f in frames), encoding="utf-8")
    counts = {"walls": 1, "floors": 0, "objects": 0, "doors": 0, "windows": 0, "openings": 0}
    geometry = {"synthetic_fixture": True, "walls": [{"transform": np.eye(4).tolist(), "dimensions": [3, 2, 0]}]}
    write_json(root / "room.json", geometry)
    write_json(root / "roomplan" / "live-room.json", geometry)
    write_json(root / "roomplan" / "node-map.json", {"fixture": "synthetic"})
    with zipfile.ZipFile(root / "roomplan" / "room.usdz", "w") as z:
        z.writestr("room.usda", "#usda 1.0\n# synthetic fixture, no real device geometry\n")
    report = {"train_frames": 20, "validation_frames": 10, "saved_frames": 30,
              "training_camera_span_metres": .57, "first_timestamp_seconds": frames[0]["timestamp_seconds"],
              "last_timestamp_seconds": frames[-1]["timestamp_seconds"]}
    events = [{"timestamp": "2026-10-22T12:00:00Z", "name": "room_written_and_read_back"}]
    write_json(root / "diagnostics.json", {"scanId": scan, "state": "completed", "counts": counts, "capture": report, "events": events})
    (root / "events.jsonl").write_text("".join(json.dumps(e)+"\n" for e in events), encoding="utf-8")
    write_json(root / "manifest.json", {"format": "aproxx.iphone-scan", "schema_version": 1, "scan_id": scan, "room_id": scan,
              "coordinate_system": {"coordinate_space_id": scan, "units": "metres", "world": "arkit_right_handed_y_up",
                                    "camera": "arkit_right_up_back", "matrix_layout": "rows_acting_on_column_vectors",
                                    "image_axes": "right_down", "image_orientation": "native_sensor_unrotated_unmirrored",
                                    "world_alignment": "gravity", "cv_camera_basis": BASIS.tolist()},
              "files": {"frames": "frames.jsonl", "events": "events.jsonl", "room": "room.json", "usdz": "roomplan/room.usdz",
                        "node_map": "roomplan/node-map.json", "live_room": "roomplan/live-room.json", "checksums": "checksums.json"},
              "capture": report, "validation_protocol": "withheld_rgb_depth_shared_arkit_and_roomplan_mapping"})
    rehash(root)
    return frames


def rehash(root):
    files = {p.relative_to(root).as_posix(): {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
             for p in root.rglob("*") if p.is_file() and p.name != "checksums.json"}
    write_json(root / "checksums.json", {"algorithm": "sha256", "files": files})


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "capture"
        self.frames = fixture(self.root)

    def check(self):
        with Package(self.root) as package:
            return validate(package)

    def mutate_frame(self, fn):
        fn(self.frames)
        (self.root / "frames.jsonl").write_text("".join(json.dumps(f)+"\n" for f in self.frames), encoding="utf-8")
        rehash(self.root)

    def continuous(self, passed=True):
        for i, f in enumerate(self.frames):
            f['role'] = f['segment_id'] = 'capture'
            f['camera_to_world'][0][3] = i*.03
        (self.root / 'frames.jsonl').write_text(''.join(json.dumps(f)+'\n' for f in self.frames))
        manifest = json.loads((self.root / 'manifest.json').read_text())
        report = manifest['capture']
        report.update(capture_mode='continuous_guided', capture_frames=30, train_frames=30, validation_frames=0,
                      training_camera_span_metres=.87)
        report['guidance'] = {'algorithm':'observed_surface_depth_agreement_v1', 'saved_frames':30,
            'camera_span_metres':.87, 'coverage_passed':passed, 'reconstruction_verified':False,
            'surfaces':[{'id':str(i),'kind':'floor' if i==3 else 'wall','threshold':.2 if i==3 else .4,
                         'multi_view_fraction':.8 if passed else 0.} for i in range(4)]}
        manifest.update(schema_version=2, validation_protocol='continuous_capture_no_user_selected_holdout',
                        quality_status='estimated_surface_coverage_passed_reconstruction_unverified' if passed else 'needs_more_views_reconstruction_unverified')
        write_json(self.root/'manifest.json',manifest)
        diag=json.loads((self.root/'diagnostics.json').read_text())
        diag['capture']=report
        write_json(self.root/'diagnostics.json',diag)
        rehash(self.root)

    def test_continuous_capture_defaults_to_all_frames_and_retains_source_roles(self):
        self.continuous()
        self.assertEqual(self.check()[0]['schema_version'],2)
        out=prepare(self.root,Path(self.tmp.name)/'all')
        result=preflight(out,2)
        self.assertEqual((result['training_views'],result['check_views']),(30,0))
        self.assertFalse(result['heldout_metrics_available'])
        self.assertTrue(all(f['source_role']=='capture' for f in verify_dataset(out)['frames']))

    def test_legacy_all_frame_trial_does_not_modify_original_split_or_package(self):
        before=(self.root/'frames.jsonl').read_bytes()
        out=prepare(self.root,Path(self.tmp.name)/'all',mode='all-frames')
        self.assertEqual((preflight(out,2)['training_views'],preflight(out,2)['check_views']),(30,0))
        self.assertEqual((self.root/'frames.jsonl').read_bytes(),before)
        self.assertEqual(sum(f['source_role']=='validation' for f in verify_dataset(out)['frames']),10)
        self.assertEqual(len(list((out/'holdout_depth').glob('*.npz'))),0)

    def test_automatic_holdout_stays_out_of_depth_fitting(self):
        self.continuous()
        out=prepare(self.root,Path(self.tmp.name)/'automatic',mode='automatic-holdout')
        self.assertEqual((preflight(out,2)['training_views'],preflight(out,2)['check_views']),(20,10))
        self.assertTrue(preflight(out,2)['heldout_metrics_available'])
        self.assertEqual(len(list((out/'holdout_depth').glob('*.npz'))),10)
        cfg=verify_dataset(out)
        report=json.loads((out/'sensor_depth/report.json').read_text())
        self.assertEqual({v['index'] for v in report['views']},{i for i,f in enumerate(cfg['frames']) if f['role']=='train'})

    def test_continuous_capture_can_preserve_warnings_without_claiming_ready(self):
        self.continuous(passed=False)
        self.check()
        out=prepare(self.root,Path(self.tmp.name)/'warning')
        self.assertTrue(preflight(out,2)['coverage_warning'])
        with patch.object(sys,'argv',['run_poc.py',str(out),'--poc-root','unused','--out',str(out.parent/'run'),'--alignment-reviewed']):
            with self.assertRaisesRegex(ValueError,'Capture carries'):
                run_poc_main()

    def test_continuous_false_coverage_pass_is_rejected(self):
        self.continuous(passed=False)
        manifest=json.loads((self.root/'manifest.json').read_text())
        manifest['capture']['guidance']['coverage_passed']=True
        write_json(self.root/'manifest.json',manifest)
        diag=json.loads((self.root/'diagnostics.json').read_text()); diag['capture']=manifest['capture']
        write_json(self.root/'diagnostics.json',diag); rehash(self.root)
        with self.assertRaisesRegex(ValueError,'Coverage pass flag'):
            self.check()

    def test_continuous_roles_cannot_mix_with_legacy_split(self):
        self.continuous()
        self.mutate_frame(lambda frames: frames[0].update(role='train',segment_id='train'))
        with self.assertRaisesRegex(ValueError,'Invalid capture role'):
            self.check()

    def test_image_quality_warning_survives_intake_even_with_surface_coverage_pass(self):
        self.continuous()
        manifest=json.loads((self.root/'manifest.json').read_text())
        manifest['capture']['image_quality_warning_at_finish']='Increase room lighting'
        write_json(self.root/'manifest.json',manifest)
        diag=json.loads((self.root/'diagnostics.json').read_text()); diag['capture']=manifest['capture']
        write_json(self.root/'diagnostics.json',diag); rehash(self.root)
        out=prepare(self.root,Path(self.tmp.name)/'image-warning')
        self.assertTrue(preflight(out,2)['coverage_warning'])

    def test_automatic_holdout_rejects_isolated_views(self):
        from capture_pipeline import fitting_frames
        isolated=[dict(f,camera_to_world=np.eye(4).tolist()) for f in self.frames]
        for i,f in enumerate(isolated): f['camera_to_world'][0][3]=i*2.
        with self.assertRaisesRegex(ValueError,'Insufficient nearby views'):
            fitting_frames(isolated,'automatic-holdout')

    def test_all_frame_evaluation_emits_no_fake_or_training_view_metrics(self):
        out=Path(self.tmp.name)/'fit'
        result=no_holdout_evaluation(None,None,out,100,0,False)
        self.assertIsNone(result['mean_psnr'])
        self.assertEqual(result['views'],[])
        self.assertIn('not_evaluated',result['status'])
        self.assertEqual(json.loads((out/'eval/step-000100/metrics.json').read_text()),result)

    def test_full_synthetic_package_and_zip_pass(self):
        self.assertEqual(len(self.check()[1]), 30)
        archive = Path(self.tmp.name) / "capture.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as z:
            for p in self.root.rglob("*"):
                if p.is_file():
                    z.write(p, p.relative_to(self.root).as_posix())
        with Package(archive) as package:
            self.assertEqual(len(validate(package)[1]), 30)

    def test_apple_binary_plist_node_map_is_accepted_and_normalized_for_processing(self):
        mapping = {"Wall0": str(uuid.uuid4()).upper()}
        original = plistlib.dumps(mapping, fmt=plistlib.FMT_BINARY)
        (self.root / "roomplan" / "node-map.json").write_bytes(original)
        rehash(self.root)
        self.check()
        out = prepare(self.root, Path(self.tmp.name) / "prepared")
        self.assertEqual(json.loads((out / "geometry" / "node-map.json").read_text()), mapping)
        self.assertEqual((out / "geometry" / "node-map.original.bin").read_bytes(), original)

    def test_xml_plist_node_map_is_accepted(self):
        (self.root / "roomplan" / "node-map.json").write_bytes(plistlib.dumps({"Wall0": "fixture"}))
        rehash(self.root)
        self.check()

    def test_invalid_node_map_values_are_rejected(self):
        write_json(self.root / "roomplan" / "node-map.json", {"Wall0": ["invalid"]})
        rehash(self.root)
        with self.assertRaisesRegex(ValueError, "node map"):
            self.check()

    def test_changed_rgb_bytes_rejected(self):
        (self.root / self.frames[0]["rgb_path"]).write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "Checksum"):
            self.check()

    def test_unhashed_file_rejected(self):
        (self.root / "unexpected.txt").write_text("private")
        with self.assertRaisesRegex(ValueError, "inventory"):
            self.check()

    def test_unsynchronised_depth_rejected(self):
        self.mutate_frame(lambda rows: rows[0]["depth"].update(timestamp_seconds=1.))
        with self.assertRaisesRegex(ValueError, "synchronization"):
            self.check()

    def test_camera_reflection_rejected(self):
        self.mutate_frame(lambda rows: rows[0]["camera_to_world"][0].__setitem__(0, -1))
        with self.assertRaisesRegex(ValueError, "right-handed"):
            self.check()

    def test_bad_depth_intrinsics_rejected(self):
        self.mutate_frame(lambda rows: rows[0]["depth"]["intrinsics"][0].__setitem__(0, 20.))
        with self.assertRaisesRegex(ValueError, "rays"):
            self.check()

    def test_reused_asset_rejected(self):
        self.mutate_frame(lambda rows: rows[1].update(rgb_path=rows[0]["rgb_path"]))
        with self.assertRaisesRegex(ValueError, "canonical"):
            self.check()

    def test_wrong_counts_rejected(self):
        self.mutate_frame(lambda rows: rows[-1].update(role="train", segment_id="train"))
        with self.assertRaisesRegex(ValueError, "resumes"):
            self.check()

    def test_invalid_confidence_rejected(self):
        (self.root / self.frames[0]["confidence"]["path"]).write_bytes(bytes([9])*32*24)
        rehash(self.root)
        with self.assertRaisesRegex(ValueError, "confidence"):
            self.check()

    def test_missing_depth_rejected(self):
        (self.root / self.frames[0]["depth"]["path"]).write_bytes(b"\0"*32*24*4)
        rehash(self.root)
        with self.assertRaisesRegex(ValueError, "usable"):
            self.check()

    def test_traversal_and_windows_paths_rejected(self):
        for name in ["../room.json", "/room.json", "C:/x", "rgb\\file.jpg", "rgb//file.jpg", "./file"]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                safe_path(name)

    def test_zip_duplicate_paths_rejected(self):
        archive = Path(self.tmp.name) / "bad.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("rgb/a.jpg", "one")
            z.writestr("RGB/A.JPG", "two")
        with self.assertRaisesRegex(ValueError, "colliding"):
            Package(archive)

    def test_preparation_preserves_roles_units_and_excludes_holdout_initialization(self):
        out = prepare(self.root, Path(self.tmp.name)/"prepared")
        result = preflight(out, factor=3)
        self.assertEqual(result["training_views"], 20)
        self.assertEqual(result["check_views"], 10)
        config, train, val, worlds, _, _, points, _ = scene_arrays(out)
        n = config["normalization"]
        self.assertAlmostEqual(n["origin"][0], .285)  # No far-away heldout camera in origin/scale.
        metric = points/n["scale"] + np.array(n["origin"])
        self.assertTrue((metric[:, 0] < 5).all())  # No far-away validation surface in seeds.
        self.assertTrue(np.allclose(metric[:, 2], -2.))  # ARKit looks toward negative Z.
        self.assertFalse(set(train) & set(val))
        with np.load(out/"sensor_depth"/"view-0000.npz") as item:
            self.assertAlmostEqual(float(item["depth"][12, 16]), 2*n["scale"], places=5)
        self.assertFalse((out/"sensor_depth"/"view-0020.npz").exists())
        self.assertTrue((out/"holdout_depth"/"view-0020.npz").exists())
        view = np.linalg.inv(worlds[0])
        projected = np.append(points[0], 1) @ view.T
        self.assertGreater(projected[2], 0)
        self.assertEqual(verify_dataset(out)["source_scan_id"], config["source_scan_id"])
        (out/"images"/self.frames[0]["frame_id"]).write_text("unexpected")
        with self.assertRaisesRegex(ValueError, "inventory"):
            verify_dataset(out)

    def test_colmap_binary_header_and_pose_roundtrip(self):
        out = prepare(self.root, Path(self.tmp.name)/"prepared")
        with (out/"sparse"/"0"/"cameras.bin").open("rb") as stream:
            self.assertEqual(struct.unpack("<Q", stream.read(8))[0], 30)
            camera = struct.unpack("<iiQQdddd", stream.read(56))
            self.assertEqual(camera[:4], (1, 1, 64, 48))
        with (out/"sparse"/"0"/"images.bin").open("rb") as stream:
            self.assertEqual(struct.unpack("<Q", stream.read(8))[0], 30)
            image = struct.unpack("<i7di", stream.read(64))
            q = np.array(image[1:5])
            self.assertAlmostEqual(abs(q[1]), 1)  # 180-degree X basis transform.
            self.assertTrue(np.allclose(image[5:8], 0))

    @unittest.skipUnless(importlib.util.find_spec("pycolmap"), "Optional independent reader; install requirements-test.txt")
    def test_independent_colmap_reader_recovers_cameras_and_points(self):
        import pycolmap
        out = prepare(self.root, Path(self.tmp.name)/"prepared")
        rec = pycolmap.Reconstruction(str(out/"sparse"/"0"))
        self.assertEqual(rec.num_reg_images(), 30)
        self.assertGreaterEqual(rec.num_points3D(), 100)
        for im in rec.images.values():
            camera = rec.cameras[im.camera_id]
            self.assertEqual(camera.model_name, "PINHOLE")
            self.assertTrue(np.allclose(camera.calibration_matrix(), [[50,0,32],[0,50,24],[0,0,1]]))
            index = int(im.name[6:12])-1
            expected = np.asarray(self.frames[index]["camera_to_world"]) @ BASIS
            view = np.eye(4)
            view[:3] = im.cam_from_world().matrix()
            self.assertTrue(np.allclose(np.linalg.inv(view), expected))

    def test_cv_basis_backprojection_and_quaternion(self):
        K = np.array([[2., 0, 1], [0, 2, 1], [0, 0, 1]])
        points = backproject(np.full((3, 3), 2.), K, BASIS)
        self.assertTrue(np.allclose(points[1, 1], [0, 0, -2]))
        self.assertTrue(np.allclose(points[2, 2], [1, -1, -2]))
        a = .7
        R = np.array([[np.cos(a), 0, np.sin(a)], [0, 1, 0], [-np.sin(a), 0, np.cos(a)]])
        self.assertTrue(np.allclose(quaternion(R), [np.cos(a/2), 0, np.sin(a/2), 0]))

    def test_conversion_never_overwrites_existing_dataset(self):
        out = Path(self.tmp.name)/"prepared"
        out.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            prepare(self.root, out)

    def test_processed_room_alignment_uses_correspondences_not_identity_guess(self):
        final, live = {"walls": []}, {"walls": []}
        correction = BASIS.copy()
        correction[:3, 3] = [2., 0., -1.]
        for i in range(4):
            wall = np.eye(4)
            wall[:3, 3] = [i, i % 2, 0]
            final["walls"].append({"identifier": str(i), "transform": wall.flatten(order="F").tolist()})
            live["walls"].append({"identifier": str(i), "transform": (correction @ wall).flatten(order="F").tolist()})
        result = room_alignment(live, final)
        self.assertEqual(result["status"], "matched_geometry_requires_physical_review")
        self.assertTrue(np.allclose(result["processed_to_capture_world"], correction))
        live["walls"][0]["transform"][12] += 2
        self.assertEqual(room_alignment(live, final)["status"], "geometry_disagreement")


if __name__ == "__main__":
    unittest.main()
