import json
import plistlib
import tempfile
import unittest
import uuid
import zipfile
from pathlib import Path

from select_simulator import select
from validate_scan import validate
from verify_ipa import verify


class ExportValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.room = {"walls": [{"transform": [1] * 16, "dimensions": [3, 2.5, 0]}],
                     "doors": [], "windows": [], "objects": []}
        self.diagnostics = {
            "scanId": str(uuid.uuid4()), "state": "completed",
            "completedAt": "2026-10-22T09:00:00.000Z",
            "counts": {"walls": 1, "doors": 0, "windows": 0, "objects": 0},
            "events": [{"name": "room_written_and_read_back"}],
        }

    def save(self):
        (self.folder / "room.json").write_text(json.dumps(self.room), encoding="utf-8")
        (self.folder / "diagnostics.json").write_text(json.dumps(self.diagnostics), encoding="utf-8")

    def test_matching_files_pass(self):
        self.save()
        scan_id, counts = validate(self.folder)
        self.assertEqual(scan_id, self.diagnostics["scanId"])
        self.assertEqual(counts["walls"], 1)

    def test_count_mismatch_fails(self):
        self.diagnostics["counts"]["walls"] = 4
        self.save()
        with self.assertRaisesRegex(ValueError, "count differs"):
            validate(self.folder)

    def test_cancelled_attempt_fails(self):
        self.diagnostics["state"] = "cancelled"
        self.save()
        with self.assertRaisesRegex(ValueError, "completed"):
            validate(self.folder)

    def test_geometry_missing_fails(self):
        self.room["walls"] = [{}]
        self.save()
        with self.assertRaisesRegex(ValueError, "transform or dimensions"):
            validate(self.folder)

    def test_missing_readback_event_fails(self):
        self.diagnostics["events"] = []
        self.save()
        with self.assertRaisesRegex(ValueError, "read-back"):
            validate(self.folder)

    def test_empty_walls_fail(self):
        self.room["walls"] = []
        self.diagnostics["counts"]["walls"] = 0
        self.save()
        with self.assertRaisesRegex(ValueError, "No wall"):
            validate(self.folder)


class IpaValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.ipa = Path(self.temp.name) / "fixture.ipa"
        self.info = {
            "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "17.0",
            "NSCameraUsageDescription": "Test permission",
            "CFBundleIdentifier": "be.aproxx.roomplanDeviceTest",
        }

    def save(self, prefix="Payload/Runner.app/"):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(prefix + "Info.plist", plistlib.dumps(self.info))
            archive.writestr(prefix + "Runner", b"package fixture, not an actual executable")

    def test_device_package_structure_passes(self):
        self.save()
        self.assertEqual(verify(self.ipa)["MinimumOSVersion"], "17.0")

    def test_simulator_build_is_rejected(self):
        self.info["CFBundleSupportedPlatforms"] = ["iPhoneSimulator"]
        self.save()
        with self.assertRaisesRegex(ValueError, "not an iPhone"):
            verify(self.ipa)

    def test_wrong_archive_layout_is_rejected(self):
        self.save("Runner.app/")
        with self.assertRaisesRegex(ValueError, "Payload/Runner.app"):
            verify(self.ipa)


class SimulatorSelectionTests(unittest.TestCase):
    def test_selects_available_recent_iphone(self):
        self.assertEqual(select({"devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                {"name": "iPhone 16", "isAvailable": True, "udid": "chosen"},
                {"name": "iPhone 16 Pro", "isAvailable": False, "udid": "unavailable"}],
            "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [
                {"name": "iPhone 14", "isAvailable": True, "udid": "too-old"}],
        }}), "chosen")

    def test_no_compatible_simulator_fails(self):
        with self.assertRaisesRegex(ValueError, "No available"):
            select({"devices": {}})


if __name__ == "__main__":
    unittest.main()
