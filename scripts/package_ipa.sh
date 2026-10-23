#!/usr/bin/env bash
set -euo pipefail

# Run from this standalone project's root on the Codemagic Mac.
test "$(uname -s)" = Darwin
test -f pubspec.yaml
app="$PWD/build/ios/iphoneos/Runner.app"
output="$PWD/build/ipa/RoomPlanTest-unsigned.ipa"
test -f "$app/Runner"
plutil -lint "$app/Info.plist"
if [ ! -f "$app/PrivacyInfo.xcprivacy" ]; then
  echo 'Runner.app is missing PrivacyInfo.xcprivacy. Check Runner resource membership and unique Xcode object IDs.' >&2
  exit 1
fi
plutil -lint "$app/PrivacyInfo.xcprivacy"
case "$(lipo -archs "$app/Runner")" in
  *arm64*) ;;
  *) echo 'Expected an arm64 iPhone executable.' >&2; exit 1 ;;
esac
mkdir -p "$PWD/build/ipa"
stage=$(mktemp -d "$PWD/build/ipa/package.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/Runner.app"
# zip updates existing archives; remove only this workflow's exact output first.
if [ -f "$output" ]; then rm -- "$output"; fi
(cd "$stage" && zip -q -r -y "$output" Payload)
python3 scripts/verify_ipa.py "$output" --capture-controls
printf 'Unsigned IPA ready for local re-signing: %s\n' "$output"
