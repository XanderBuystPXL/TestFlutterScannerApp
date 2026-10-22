"""Check the package shape and device metadata, without claiming it is signed."""
import argparse
import plistlib
import zipfile


def verify(path):
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
        return info


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    args = parser.parse_args()
    try:
        metadata = verify(args.ipa)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f"IPA check failed: {error}\n")
    print(f"IPA structure passed: {metadata['CFBundleIdentifier']} (unsigned; installation untested).")
