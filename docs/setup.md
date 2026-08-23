# Setup

## What You Need

- a Mac with Xcode installed
- an Apple ID
- an Apple Developer membership if you want full signing/distribution capabilities
- Git
- optional: OpenAI Codex or Anthropic Claude Code for agent-assisted development

## Apple Account And Xcode

For local simulator development, Xcode alone is enough.

For device builds and iCloud entitlements, you should expect to:

1. sign into Xcode with your Apple ID
2. enroll in the Apple Developer Program if required for your intended workflow
3. create or reuse an app identifier and iCloud container under your own Apple team
4. let Xcode manage signing automatically unless you have a reason not to

Official starting points:

- Apple Developer enrollment: `https://developer.apple.com/programs/enroll/`
- Xcode download and release page: `https://developer.apple.com/xcode/`

## Clone And First Build

1. Clone the repo.
2. Copy [`Config/Local.example.xcconfig`](../Config/Local.example.xcconfig) to `Config/Local.xcconfig`.
3. Replace the placeholder values:
   - `OPENLIFT_APP_BUNDLE_ID`
   - `OPENLIFT_TEST_BUNDLE_ID`
   - `OPENLIFT_UI_TEST_BUNDLE_ID`
   - `OPENLIFT_ICLOUD_CONTAINER`
   - `OPENLIFT_KVSTORE_ID`
   - `OPENLIFT_DEVELOPMENT_TEAM`
4. Open [`OpenLift.xcodeproj`](../OpenLift.xcodeproj).
5. Build for simulator first.
6. Then test a device build if you need iCloud and physical-phone behavior.

## Why The Config Is Split

Tracked config files under [`Config`](../Config) contain public app identifiers,
entitlement names, and build settings. Apple bundle, team, issuer, and key IDs
are identifiers rather than credentials, but private keys, signing certificates,
bearer tokens, and private endpoints do not belong in tracked files.

The ignored local override:

- keeps your personal bundle ids out of git
- keeps your Apple team id out of git
- lets you keep using your real iCloud container on your own Mac

## Common Xcode Commands

Simulator tests:

```bash
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17'
```

Device build:

```bash
xcodebuild -scheme OpenLift -destination 'id=<DEVICE_UDID>' -configuration Debug build
```

Show destinations:

```bash
xcodebuild -scheme OpenLift -showdestinations
```

## TestFlight Deployment

TestFlight requires a paid Apple Developer Program membership and an App Store
Connect app record for the configured bundle identifier.

Archive locally without uploading:

```bash
scripts/testflight-deploy.sh archive
```

Archive and upload:

```bash
scripts/testflight-deploy.sh
```

The script assigns a UTC timestamp build number, keeps generated archives under
`.build/testflight/`, and refuses to deploy a dirty worktree by default.

This repository script uses Xcode's automatic-signing archive path. It works in
an interactive Aqua/Xcode login session with the signing identity available in
Keychain. It does **not** work from OpenClaw's headless System security session,
where Keychain signing identities are unavailable. Headless OpenClaw deployment
must use the canonical workspace device/TestFlight deployment scripts, which
build unsigned and sign from private material stored outside this repository.
Those scripts and their private configuration are intentionally not copied or
documented here.

It can use the Apple account saved in Xcode. For unattended deployment, create
an App Store Connect API key and provide all three values:

```bash
ASC_KEY_ID=... \
ASC_ISSUER_ID=... \
ASC_PRIVATE_KEY_PATH=/absolute/path/to/AuthKey_....p8 \
scripts/testflight-deploy.sh
```

Do not commit the private key. Optional overrides are
`OPENLIFT_BUILD_NUMBER`, `OPENLIFT_MARKETING_VERSION`,
`OPENLIFT_TESTFLIGHT_OUTPUT_DIR`, and `OPENLIFT_ALLOW_DIRTY=1`.

## iCloud Expectations

The app uses iCloud Documents style storage for:

- published cycles in `OpenLift/cycles`
- completed exports in `OpenLift/exports`
- draft exports in `OpenLift/exports/drafts`

If iCloud is unavailable, workout exports fall back to the app's local documents directory.

## Safe Local Hygiene

Do not commit:

- `Config/Local.xcconfig`
- `.p8`, `.p12`, `.pem`, or `.key` signing material
- provisioning profiles
- app container dumps
- SwiftData/SQLite stores and their `-wal`/`-shm` sidecars
- exported workout JSON from your own usage
- Xcode user-state files
- archives, IPAs, dSYMs, and local build output

The repo ignores these classes via [`.gitignore`](../.gitignore), but keep
credential and personal-data artifacts outside the checkout as the primary
boundary. Before publishing, scan both the current tree and reachable history;
GitHub secret scanning and push protection are a second line of defense, not a
replacement for local hygiene.
