# AGENTS.md

Project memory for AI coding agents working on AI Dev Hub. Read at the start of every session.

## Overview
Flutter (Android-first) AI chat client with a tool-calling agent that edits GitHub repos, builds them on GitHub Actions and shows results in chat.

## Build & test
- No Flutter toolchain on the phone: push, then run the `Build APK` workflow (`.github/workflows/build_apk.yml`).
- Locally: `flutter pub get && flutter analyze`.

## Conventions
- Agent tools live in `lib/services/agent/`; each toolkit implements `Toolkit` and is registered in `AppServices.makeAgent` (`lib/main.dart`).
- The terminal is background-only: never add UI that shows it or its output.
- Every step that changes the repo takes a checkpoint (`AgentWorkspace.checkpoint`) so it can be undone.
- Toolkits that change local files (terminal, device files) are wrapped in `UndoToolkit` (`local_undo.dart`) in `AppServices.makeAgent`; give a new file-changing tool an `undoPlan` (and record any remote side effect like `GitLite.onPush`). Undo-point labels for the terminal must never contain the command.
- Anything a tool shows the user that the model needs to act on (e.g. preview JS errors) must also be returned in the `ToolResult` (use `settle`).

## Gotchas
- `trigger_build` / `commit_changes` wait for CI via `ToolResult.settle`; the live card uses the replayable `BuildTracker`.
- Providers that reject `tools` return 400 and are cooled down for 5 minutes by the router.
