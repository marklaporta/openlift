#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
cd "$repo_root"

mode=${1:-upload}
if [[ "$mode" != "archive" && "$mode" != "upload" ]]; then
  print -u2 "Usage: $0 [archive|upload]"
  exit 2
fi

if [[ "${OPENLIFT_ALLOW_DIRTY:-0}" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "Refusing to deploy a dirty worktree. Commit first or set OPENLIFT_ALLOW_DIRTY=1."
  exit 2
fi

build_number=${OPENLIFT_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}
marketing_version=${OPENLIFT_MARKETING_VERSION:-1.0}
output_root=${OPENLIFT_TESTFLIGHT_OUTPUT_DIR:-"$repo_root/.build/testflight/$build_number"}
archive_path="$output_root/OpenLift.xcarchive"
export_path="$output_root/export"
mkdir -p "$output_root"

auth_args=()
if [[ -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" || -n "${ASC_PRIVATE_KEY_PATH:-}" ]]; then
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" || -z "${ASC_PRIVATE_KEY_PATH:-}" ]]; then
    print -u2 "ASC_KEY_ID, ASC_ISSUER_ID, and ASC_PRIVATE_KEY_PATH must be set together."
    exit 2
  fi
  if [[ ! -f "$ASC_PRIVATE_KEY_PATH" ]]; then
    print -u2 "App Store Connect private key not found: $ASC_PRIVATE_KEY_PATH"
    exit 2
  fi
  auth_args=(
    -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

print "Archiving OpenLift $marketing_version ($build_number)…"
xcodebuild archive \
  -project OpenLift.xcodeproj \
  -scheme OpenLift \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" \
  -allowProvisioningUpdates \
  "${auth_args[@]}" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number"

if [[ "$mode" == "archive" ]]; then
  print "Archive created at $archive_path"
  exit 0
fi

print "Uploading OpenLift $marketing_version ($build_number) to App Store Connect…"
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist Config/TestFlightExportOptions.plist \
  -allowProvisioningUpdates \
  "${auth_args[@]}"

print "Upload accepted. Build $build_number will appear in TestFlight after Apple finishes processing it."
