"""Guard Runner's serialized Xcode resource/source graph before expensive builds.

This reads the checked-in Xcode/OpenStep layout, not arbitrary plist syntax.
It catches duplicate object IDs before a plist reader can silently overwrite them.
The built IPA still receives independent content validation.
"""
import argparse
from collections import Counter
from pathlib import Path
import re


DEFINITION = re.compile(r"^\t\t([A-F0-9]{24})(?: /\*[^\n]*?\*/)? = \{", re.MULTILINE)
OBJECT = re.compile(r"^\t\t([A-F0-9]{24})(?: /\*[^\n]*?\*/)? = "
                    r"(\{[^\n]*\};|\{\n.*?^\t\t\};)", re.MULTILINE | re.DOTALL)


def field(body, name):
    match = re.search(r"\b" + re.escape(name) + r'\s*=\s*(?:"([^"]*)"|([^;\n]+))\s*;', body)
    return (match.group(1) if match.group(1) is not None else match.group(2).strip()) if match else None


def references(body, name):
    match = re.search(r"\b" + re.escape(name) + r"\s*=\s*\((.*?)\);", body, re.DOTALL)
    return re.findall(r"\b[A-F0-9]{24}\b", match.group(1)) if match else []


def validate_project(text):
    counts = Counter(DEFINITION.findall(text))
    duplicates = sorted(key for key, count in counts.items() if count > 1)
    if duplicates:
        raise ValueError("Duplicate Xcode object IDs: " + ", ".join(duplicates))
    objects = dict(OBJECT.findall(text))
    if not objects or set(objects) != set(counts):
        raise ValueError("Unsupported Xcode object layout; source graph was not fully checked.")
    runners = [body for body in objects.values() if field(body, "isa") == "PBXNativeTarget" and field(body, "name") == "Runner"]
    if len(runners) != 1:
        raise ValueError("Expected one Runner application target.")
    phases = {}
    for phase_id in references(runners[0], "buildPhases"):
        body = objects.get(phase_id, "")
        if not body:
            raise ValueError(f"Missing build phase: {phase_id}")
        kind = field(body, "isa")
        files = phases.setdefault(kind, set())
        for build_id in references(body, "files"):
            build = objects.get(build_id, "")
            ref = field(build, "fileRef")
            file_id = re.match(r"[A-F0-9]{24}", ref or "")
            if field(build, "isa") != "PBXBuildFile" or not file_id or file_id.group() not in objects:
                raise ValueError(f"Unresolved build-file reference: {build_id}")
            files.add(file_id.group())
    for filename, kind in [("PrivacyInfo.xcprivacy", "PBXResourcesBuildPhase"),
                           ("CaptureGuidance.swift", "PBXSourcesBuildPhase")]:
        refs = [key for key, body in objects.items()
                if field(body, "isa") == "PBXFileReference" and field(body, "path") == filename]
        if len(refs) != 1 or refs[0] not in phases.get(kind, set()):
            raise ValueError(f"Runner must include {filename} in {kind}.")
    return len(objects)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    args = parser.parse_args()
    try:
        count = validate_project(args.project.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Xcode project check failed: {error}\n")
    print(f"Xcode project passed: {count} unique object IDs; Runner privacy resource and guidance source resolve correctly.")


if __name__ == "__main__":
    main()
