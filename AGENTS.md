# Repository Guidelines

## Project Structure & Module Organization
This repository is currently PRD-first and contains one source of truth: `prd.md` (Hypertrophy Rotation Tracker requirements).
As implementation begins, keep a predictable layout:
- `src/` application code (group by domain: `cycle/`, `session/`, `export/`)
- `tests/` unit and integration tests mirroring `src/`
- `assets/` static fixtures or sample JSON payloads
- `docs/` design notes and API/data-model decisions

Keep data model names aligned with the PRD (`Exercise`, `CycleTemplate`, `ActiveCycleInstance`, `Session`, `SetEntry`).

## Build, Test, and Development Commands
No build tooling is committed yet. When adding runtime/tooling, expose standard commands through a single entry point (`Makefile` or package scripts).
Recommended baseline:
- `make dev` or `npm run dev`: run app locally
- `make test` or `npm test`: run full test suite
- `make lint` or `npm run lint`: static analysis and style checks
- `make format` or `npm run format`: auto-format code

Document final command choices in this file and keep examples up to date.

## Coding Style & Naming Conventions
Use 4 spaces for indentation in Markdown/JSON examples; follow language defaults in code formatters.
Naming:
- Types/classes: `PascalCase`
- Variables/functions: `camelCase`
- File names: `<feature>.<role>.<ext>` when useful (example: `session.service.ts`)
- Tests: `<unit>.test.<ext>`

Prefer small, deterministic modules. Keep business logic (rotation/session rules) separate from storage and UI layers.

## Testing Guidelines
Use deterministic tests for rotation advancement, set add/remove behavior, prefill logic, and export payload shape.
Minimum expectations for new logic:
- unit tests for happy path + edge cases
- regression test for each bug fix
- fixtures for PRD-conformant JSON models

## Commit & Pull Request Guidelines
This workspace has no visible commit history yet, so use Conventional Commits going forward:
- `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`

PRs should include:
- concise summary of behavior changes
- linked issue/task (if available)
- test evidence (command + result)
- sample payload/screenshot when UI or export output changes

## Security & Configuration Tips
Do not commit secrets or personal training exports. Keep environment values in `.env.local` (ignored), and provide safe defaults via `.env.example`.
