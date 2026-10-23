"""Check the source graph responsible for app-resource packaging, without Xcode."""
from pathlib import Path
import unittest

from check_xcode_project import validate_project


class XcodeProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = (Path(__file__).resolve().parents[1] / "ios/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")

    def test_runner_resolves_application_privacy_resource_and_guidance_source(self):
        self.assertGreater(validate_project(self.project), 0)

    def test_guidance_privacy_identifier_collision_is_rejected(self):
        broken = self.project.replace("A9C012000000000000000007", "A9C012000000000000000006").replace(
            "A9C012000000000000000017", "A9C012000000000000000016")
        with self.assertRaisesRegex(ValueError, "Duplicate Xcode object IDs"):
            validate_project(broken)

    def test_manifest_file_without_runner_resource_membership_is_rejected(self):
        entry = "\t\t\t\tA9C012000000000000000006 /* PrivacyInfo.xcprivacy in Resources */,\n"
        self.assertIn(entry, self.project)
        with self.assertRaisesRegex(ValueError, "PrivacyInfo.xcprivacy.*PBXResourcesBuildPhase"):
            validate_project(self.project.replace(entry, ""))

    def test_guidance_source_pointing_at_the_privacy_file_is_rejected(self):
        original = "fileRef = A9C012000000000000000017 /* CaptureGuidance.swift */"
        self.assertIn(original, self.project)
        broken = self.project.replace(original, "fileRef = A9C012000000000000000016 /* PrivacyInfo.xcprivacy */")
        with self.assertRaisesRegex(ValueError, "CaptureGuidance.swift.*PBXSourcesBuildPhase"):
            validate_project(broken)


if __name__ == "__main__":
    unittest.main()
