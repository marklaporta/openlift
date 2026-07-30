#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
supplied_backup=${1:-}
simulator_udid=${OPENLIFT_SIMULATOR_UDID:-}

if [[ -z "$supplied_backup" ]]; then
  print -u2 "Usage: $0 <device-store-directory|backup-archive.tgz>"
  print -u2 "A directory must contain default.store plus any sidecars."
  print -u2 "An archive is extracted read-only and searched for the directory holding default.store."
  exit 2
fi

build_root=$(mktemp -d "${TMPDIR:-/tmp}/OpenLiftRealStoreMigration.XXXXXX")
trap 'rm -rf "$build_root"' EXIT

# The supplied path is never written to. Archives are extracted into the scratch
# build root, and the extracted copy becomes the staging source.
integrity_targets=()
if [[ -d "$supplied_backup" ]]; then
  backup_directory=${supplied_backup:A}
elif [[ -f "$supplied_backup" ]]; then
  case "$supplied_backup" in
    *.tgz|*.tar.gz|*.tar)
      ;;
    *)
      print -u2 "Unsupported backup archive: $supplied_backup"
      print -u2 "Supported extensions are .tgz, .tar.gz, and .tar."
      exit 2
      ;;
  esac

  archive_path=${supplied_backup:A}
  integrity_targets=("$archive_path")
  extract_root="$build_root/extracted"
  mkdir -p "$extract_root"
  print "Extracting $archive_path into a scratch copy…"
  tar -xf "$archive_path" -C "$extract_root"

  backup_directory=$(
    find "$extract_root" -type f -name default.store -print |
      sort |
      head -1 |
      xargs -I{} dirname {}
  )
  if [[ -z "$backup_directory" ]]; then
    print -u2 "No default.store found anywhere inside $archive_path"
    exit 2
  fi
  print "Using extracted store directory: ${backup_directory#$extract_root/}"
else
  print -u2 "Backup path is neither a directory nor a file: $supplied_backup"
  exit 2
fi

if [[ ! -f "$backup_directory/default.store" ]]; then
  print -u2 "Missing real-store fixture file: $backup_directory/default.store"
  exit 2
fi

# Sidecars are optional: a checkpointed store may legitimately ship without them.
staged_files=("$backup_directory/default.store")
for filename in default.store-wal default.store-shm; do
  if [[ -f "$backup_directory/$filename" ]]; then
    staged_files+=("$backup_directory/$filename")
  else
    print "Note: $filename is absent from the supplied backup; continuing without it."
  fi
done

# For a directory the source files themselves must stay untouched. For an
# archive the archive itself is the source of truth; the extracted copy is
# scratch and gets deleted with the build root.
if (( ${#integrity_targets} == 0 )); then
  integrity_targets=("${staged_files[@]}")
fi

source_manifest_before=$(shasum -a 256 "${integrity_targets[@]}")

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
cp "${staged_files[@]}" "$fixture_directory/"

print "Running the detected-version-to-head migration gate against a working copy…"
xcodebuild test \
  -project OpenLift.xcodeproj \
  -scheme OpenLift \
  -destination "platform=iOS Simulator,id=$simulator_udid" \
  -derivedDataPath "$build_root/DerivedData" \
  -parallel-testing-enabled NO \
  -only-testing:OpenLiftTests/MigrationSafetyTests/testCopiedRealDeviceStoreMigratesToCurrentSchemaWhenOptedIn

source_manifest_after=$(shasum -a 256 "${integrity_targets[@]}")

if [[ "$source_manifest_after" != "$source_manifest_before" ]]; then
  print -u2 "The supplied backup changed while the migration test ran."
  exit 1
fi
