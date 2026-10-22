"""Read simctl JSON on stdin and select an available iOS 17+ iPhone."""
import json
import re
import sys


def select(data):
    choices = []
    for runtime, devices in data.get("devices", {}).items():
        match = re.search(r"\.iOS-(\d+)-(\d+)", runtime)
        if not match or int(match[1]) < 17:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                choices.append(((int(match[1]), int(match[2])), device["udid"]))
    if not choices:
        raise ValueError("No available iOS 17+ iPhone simulator was found on this build image.")
    return max(choices)[1]


if __name__ == "__main__":
    try:
        print(select(json.load(sys.stdin)))
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
