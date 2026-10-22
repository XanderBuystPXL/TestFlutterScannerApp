"""Validate exported room.json and diagnostics.json together on Windows or macOS."""
import argparse
import json
import uuid
from pathlib import Path


def validate(folder):
    folder = Path(folder)
    room = json.loads((folder / "room.json").read_text(encoding="utf-8-sig"))
    diagnostics = json.loads((folder / "diagnostics.json").read_text(encoding="utf-8-sig"))
    if not isinstance(room, dict) or not isinstance(diagnostics, dict):
        raise ValueError("Both exports must contain a JSON object.")
    if diagnostics.get("state") != "completed":
        raise ValueError("The diagnostic log does not mark this scan as completed.")
    uuid.UUID(diagnostics["scanId"])
    if not diagnostics.get("completedAt"):
        raise ValueError("Missing completion timestamp.")
    if not any(event.get("name") == "room_written_and_read_back" for event in diagnostics.get("events", [])):
        raise ValueError("The log contains no successful read-back event.")
    counts = {}
    for name in ("walls", "doors", "windows", "objects"):
        # Match the native validator: omitted empty collections count as zero.
        entries = room.get(name, [])
        if not isinstance(entries, list):
            raise ValueError(f"room.json has no {name} array.")
        counts[name] = len(entries)
        if diagnostics.get("counts", {}).get(name) != counts[name]:
            raise ValueError(f"The {name} count differs between room.json and diagnostics.json.")
    if counts["walls"] == 0:
        raise ValueError("No wall geometry was saved.")
    if any(not isinstance(wall, dict) or not wall.get("transform") or not wall.get("dimensions") for wall in room["walls"]):
        raise ValueError("A wall is missing its transform or dimensions.")
    return diagnostics["scanId"], counts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", help="Folder containing the matching exported files")
    args = parser.parse_args()
    try:
        scan_id, counts = validate(args.folder)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Scan validation failed: {error}\n")
    print(f"File validation passed for scan {scan_id}: {counts}")
    print("Inspect room coverage on the iPhone; this checks files, not geometric accuracy.")
