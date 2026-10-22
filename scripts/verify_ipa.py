"""Check the package shape and device metadata, without claiming it is signed."""
import argparse
import gzip
import plistlib
import zipfile


def verify(path, capture_controls=False):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError("The IPA contains a corrupt file.")
        names = set(archive.namelist())
        prefix = "Payload/Runner.app/"
        required = {prefix + "Info.plist", prefix + "Runner"}
        if not required.issubset(names):
            raise ValueError("Expected Payload/Runner.app with Info.plist and Runner.")
        if any(".." in name.split("/") or name.startswith("/") for name in names):
            raise ValueError("The IPA contains an unsafe archive path.")
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
            raise ValueError("This is not an iPhone device build.")
        if info.get("MinimumOSVersion") != "17.0":
            raise ValueError("Expected the iOS 17.0 deployment target.")
        if not info.get("NSCameraUsageDescription"):
            raise ValueError("Missing camera permission explanation.")
        if info.get("CFBundleIdentifier") != "be.aproxx.roomplanDeviceTest":
            raise ValueError("Unexpected test bundle identifier.")
        if capture_controls:
            privacy_path = prefix + "PrivacyInfo.xcprivacy"
            if privacy_path not in names:
                raise ValueError("Missing application privacy manifest.")
            privacy = plistlib.loads(archive.read(privacy_path))
            reasons = {entry["NSPrivacyAccessedAPIType"]: entry["NSPrivacyAccessedAPITypeReasons"]
                       for entry in privacy["NSPrivacyAccessedAPITypes"]}
            if privacy.get("NSPrivacyTracking") is not False or privacy.get("NSPrivacyCollectedDataTypes") != []:
                raise ValueError("Unexpected tracking/data-collection declaration.")
            if "35F9.1" not in reasons.get("NSPrivacyAccessedAPICategorySystemBootTime", []) or "C617.1" not in reasons.get("NSPrivacyAccessedAPICategoryFileTimestamp", []):
                raise ValueError("Missing capture required-reason API declarations.")
            notices = [n for n in names if n.startswith(prefix) and n.endswith("/flutter_assets/NOTICES.Z")]
            if len(notices) != 1 or "copyright" not in gzip.decompress(archive.read(notices[0])).decode("utf-8").lower():
                raise ValueError("Missing or unreadable bundled dependency licence notices.")
            if (info.get("CFBundleShortVersionString"), str(info.get("CFBundleVersion"))) != ("0.2.0", "3"):
                raise ValueError("Expected full-capture app version 0.2.0 (3).")
        return info


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--capture-controls", action="store_true")
    args = parser.parse_args()
    try:
        metadata = verify(args.ipa, args.capture_controls)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f"IPA check failed: {error}\n")
    print(f"IPA structure passed: {metadata['CFBundleIdentifier']} (unsigned; installation untested).")
