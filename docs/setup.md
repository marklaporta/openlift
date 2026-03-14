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
   - `OPENLIFT_ICLOUD_CONTAINER`
   - `OPENLIFT_KVSTORE_ID`
   - `OPENLIFT_DEVELOPMENT_TEAM`
4. Open [`OpenLift.xcodeproj`](../OpenLift.xcodeproj).
5. Build for simulator first.
6. Then test a device build if you need iCloud and physical-phone behavior.

## Why The Config Is Split

Tracked config files under [`Config`](../Config) keep the public repo safe.

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

## iCloud Expectations

The app uses iCloud Documents style storage for:

- published cycles in `OpenLift/cycles`
- completed exports in `OpenLift/exports`
- draft exports in `OpenLift/exports/drafts`

If iCloud is unavailable, workout exports fall back to the app's local documents directory.

## Safe Local Hygiene

Do not commit:

- `Config/Local.xcconfig`
- app container dumps
- exported workout JSON from your own usage
- Xcode user-state files
- random `DerivedData` output

The repo already ignores the usual local-only files via [`.gitignore`](../.gitignore).
