# AI Workflows

## What Codex And Claude Code Are Good At Here

Both Codex and Claude Code work well for:

- editing SwiftUI and SwiftData code
- running `xcodebuild` tests
- inspecting simulator or device logs
- generating or updating published workout template JSON
- debugging cycle progression, history hydration, and export logic

They are most effective when used from a terminal with access to the repo and Xcode command line tools.

Official docs:

- OpenAI Codex docs: `https://platform.openai.com/docs/codex/overview`
- Claude Code docs: `https://docs.anthropic.com/en/docs/claude-code/overview`

## What They Cannot Magically Do

They do not automatically get:

- your Apple account
- your iCloud permissions
- GitHub auth
- your physical device trust relationship

Those depend on the local Mac configuration.

## Practical Capabilities In This Repo

With the right local setup, an agent can:

- run `xcodebuild test`
- build for simulator or device
- inspect Xcode destinations
- install and launch the app with `devicectl`
- read and write published cycle files
- inspect exported workout JSON

## Good Agent Task Types

- "add a built-in starter template and tests"
- "fix history hydration for mixed cycle histories"
- "generate a 5-day upper/lower/arms published cycle JSON"
- "inspect why the current draft does not match the active cycle"
- "install the latest device build and relaunch the app"

## Prompting Tips

Be explicit about:

- whether the task is code-only or may touch real user data
- whether the target is simulator or physical device
- whether the output should be Swift code, JSON, or a migration/recovery step
- whether published-cycle import should win over built-in fallback behavior

## Xcode And Apple Tooling From Agents

Useful commands:

```bash
xcodebuild -scheme OpenLift -showdestinations
xcodebuild test -scheme OpenLift -destination 'platform=iOS Simulator,name=iPhone 17'
xcrun devicectl list devices
xcrun simctl list
```

## Working With iCloud

Agents can safely work on:

- code that reads and writes iCloud-backed files
- published cycle JSON structure
- export payload structure

Agents should not assume:

- iCloud is available on the machine
- the container is populated
- a given physical device is unlocked

## Working With User Data

If you ask an agent to inspect or change user data, say which level you mean:

- app code
- published templates
- exports
- SwiftData store on simulator
- SwiftData store on a physical device

That distinction matters because the risk and tooling are different.

## Recommended Maintenance Pattern

For ongoing development:

1. keep product-safe defaults in tracked config and docs
2. keep personal Apple settings in `Config/Local.xcconfig`
3. use agents for code and test loops
4. use published JSON for template experimentation
5. touch real stored history only when necessary and with backups
