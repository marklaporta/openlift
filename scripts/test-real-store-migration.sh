#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
backup_directory=${1:-}
simulator_udid=${OPENLIFT_SIMULATOR_UDID:-}

if [[ -z "$backup_directory" ]]; then
  print -u2 "Usage: $0 <device-store-directory>"
  print -u2 "The directory must contain default.store, default.store-wal, and default.store-shm."
  exit 2
fi

for filename in default.store default.store-wal default.store-shm; do
  if [[ ! -f "$backup_directory/$filename" ]]; then
    print -u2 "Missing real-store fixture file: $backup_directory/$filename"
    exit 2
  fi
done

source_manifest_before=$(
  shasum -a 256 \
    "$backup_directory/default.store" \
    "$backup_directory/default.store-wal" \
    "$backup_directory/default.store-shm"
)

if [[ -z "$simulator_udid" ]]; then
  simulator_udid=$(
    xcrun simctl list devices available |
      sed -nE 's/^[[:space:]]*iPhone 17 \(([0-9A-F-]+)\) \((Booted|Shutdown)\)[[:space:]]*$/\1/p' |
      head -1
  )
fi

if [[ -z "$simulator_udid" ]]; then
  print -u2 "No available iPhone 17 simulator found. Set OPENLIFT_SIMULATOR_UDID explicitly."
  exit 2
fi

build_root=$(mktemp -d "${TMPDIR:-/tmp}/OpenLiftRealStoreMigration.XXXXXX")
trap 'rm -rf "$build_root"' EXIT

cd "$repo_root"

print "Building the OpenLift test host for simulator $simulator_udid…"
xcodebuild build-for-testing \
  -project OpenLift.xcodeproj \
  -scheme OpenLift \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$build_root/DerivedData"

xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl install \
  "$simulator_udid" \
  "$build_root/DerivedData/Build/Products/Debug-iphonesimulator/OpenLift.app"

data_container=$(
  xcrun simctl get_app_container "$simulator_udid" com.mark.openlift data
)
fixture_directory="$data_container/Documents/OpenLiftCopiedRealDeviceStore"
mkdir -p "$fixture_directory"
cp \
  "$backup_directory/default.store" \
  "$backup_directory/default.store-wal" \
  "$backup_directory/default.store-shm" \
  "$fixture_directory/"

print "Running the detected-version-to-head migration gate against a working copy…"
xcodebuild test \
  -project OpenLift.xcodeproj \
  -scheme OpenLift \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$build_root/DerivedData" \
  -parallel-testing-enabled NO \
  -only-testing:OpenLiftTests/MigrationSafetyTests/testCopiedRealDeviceStoreMigratesToCurrentSchemaWhenOptedIn

source_manifest_after=$(
  shasum -a 256 \
    "$backup_directory/default.store" \
    "$backup_directory/default.store-wal" \
    "$backup_directory/default.store-shm"
)

if [[ "$source_manifest_after" != "$source_manifest_before" ]]; then
  print -u2 "The supplied backup changed while the migration test ran."
  exit 1
fi
