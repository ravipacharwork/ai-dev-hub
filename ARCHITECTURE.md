# AI Dev Hub — Architecture Blueprint

## 1. What the two gateway repos actually are

I read both READMEs before designing the router layer. Two findings change the design:

| | OmniRoute |
|---|---|---|
| What it is | Self-hosted Node server (Docker / desktop / experimental Termux) | Self-hosted Node/Next.js gateway (npm / Docker / desktop) |
| Endpoint | `http://host:3001/v1` + unified `freellmapi-…` bearer | `http://host:20128/v1`, model `auto` works zero-config |
| Routing | Fallback chain, per-key RPM/RPD/TPM/TPD tracking, `auto`, `auto:<profile>` | 19 strategies, `auto`, `auto/coding`, `auto/fast`, `auto/cheap`, circuit breakers, key cooldowns |
| "Always up to date" | Signed Ed25519 catalog from freellmapi.co. **Free installs get the monthly snapshot (30 days behind); same-day is the paid tier** | Catalog ships with releases; optional signed "Radar" overlay for supporters |
| Debug header | `X-Routed-Via: platform/model` | `X-OmniRoute-Decision` |

**Consequence:** neither project publishes a documented, app-consumable "router definitions API". Both are servers you run, not feeds you subscribe to. So "fetch router definitions from upstream" cannot mean calling their internal catalog directly (I didn't verify the catalog format, and it's signature-pinned to their own server).

**Design that works instead — three layers:**

1. **Gateway Mode (real OmniRoute / OmniRoute):** the user points the *Custom* provider at their own instance (`http://<pc-or-vps>:20128/v1`, model `auto`). The gateway does the sophisticated routing. The app just needs `GET /v1/models` to stay current (live sync, zero app updates).
2. **Direct Mode:** the app's own lightweight `RouterService` (included) does priority fallback + cooldowns across the providers the user has keys for.
3. **Remote registry:** `assets/providers.json` is bundled, and refreshed at launch from a URL you control (raw file in your own GitHub repo, ETag-cached, optional Ed25519 signature). This is how new base URLs / model IDs reach users without an app update.

## 2. Tech stack recommendation: **Flutter (Android-first)**

| Requirement | Flutter | React Native/Expo | Kotlin + Compose |
|---|---|---|---|
| SAF file access | Packages (`saf_util`, `saf_stream`) or small MethodChannel | Weak/patchy libs | Native, best |
| Local HTTP server | `shelf` (pure Dart) | Needs native module | Ktor/NanoHTTPD |
| Background server | `flutter_foreground_task` | Native work needed | Native foreground service |
| Blur/glass, haptics, animation | `BackdropFilter`, `HapticFeedback`, 120fps Skia/Impeller — excellent for Apple-style UI | OK | Good, blur is API 31+ |
| Secure storage | `flutter_secure_storage` (EncryptedSharedPreferences / Keychain) | OK | Native |
| Streaming SSE + GitHub REST | `dio` | OK | OkHttp |
| iOS later | Same codebase | Same | Rewrite |

**Pick Flutter.** One codebase, the glass/Cupertino aesthetic is the easiest to get right, and `shelf` makes the proxy trivial. Choose Kotlin only if SAF becomes your main product surface; Flutter's SAF packages cover read/write/list/delete but not every edge case.

Platform realities to design around:
- **Proxy server is Android-only in practice.** iOS suspends background sockets within seconds.
- **Android needs a foreground service + notification** to keep the proxy alive.
- **Installing the downloaded APK** needs `REQUEST_INSTALL_PACKAGES` and a `FileProvider`; the user must grant "install unknown apps" once.

## 3. Project structure

```
ai_dev_hub/
├── pubspec.yaml
├── assets/providers.json            # bundled registry (fallback)
├── .github/workflows/android-build.yml   # copy into repos you want to build remotely
└── lib/
    ├── main.dart                    ✅ wiring, tabs, sessions, build download
    ├── core/
    │   ├── models.dart              # Endpoint, ChatRequest, errors, stats
    │   ├── theme.dart               # light/dark/system, glass tokens
    │   └── haptics.dart
    ├── services/
    │   ├── openai_compatible_client.dart   ✅ included
    │   ├── router_service.dart             ✅ included (fallback + registry sync)
    │   ├── github_service.dart             ✅ included
    │   ├── build_poller.dart               ✅ included
    │   ├── local_file_service.dart         ✅ included (SAF)
    │   ├── proxy_server.dart               ✅ included
    │   └── secure_store.dart        # keys + PAT
    ├── features/
    │   ├── chat/        # markdown+highlight, artifacts, build cards
    │   ├── providers/   # keys, test connection, latency/tokens
    │   ├── proxy/       # toggle, token, LAN IP
    │   └── settings/
    └── state/           # Riverpod providers
```

UI packages: `flutter_riverpod`, `flutter_markdown` + `flutter_highlight` (or `markdown_widget`), `url_launcher`, `open_filex` (APK install), `path_provider`, `archive` (unzip).

## 4. Chat-side agent contract

Don't parse free text for file edits. Give the model tools (OpenAI `tools` / function calling) and execute them in the app with a **confirmation sheet for every write, delete, commit, push, and build**:

`read_file`, `write_file`, `delete_file`, `list_dir`, `github_tree`, `github_read`, `github_commit(files[], message)`, `trigger_build(repo, workflow, ref)`.

Models on free tiers often have weak tool calling, so also support a fallback: the model emits fenced blocks with `path=` metadata (` ```dart path=lib/a.dart `) which the UI turns into an "Apply / Commit" card.

**Implemented (`lib/services/agent/`)** — `AgentRunner` streams a reply, accumulates `tool_calls` deltas, runs the tools, feeds results back, and loops (max 10 rounds). Tools act on the selected GitHub repo/branch through the API: `list_files`, `read_file`, `write_file`, `replace_in_file`, `delete_file`, `list_changes`, `discard_changes`, `commit_changes`, `trigger_build`. Deviations from the contract above:
- `write_file` / `replace_in_file` / `delete_file` only **stage** changes in memory (nothing leaves the device), so the confirmation sheet is at `commit_changes` (lists every file with a short preview) and `trigger_build`. Staged changes are lost if the app is killed.
- No local-folder (SAF) tools and no fenced-block `path=` fallback yet.
- Enabled by a Settings switch. A provider that rejects `tools` returns 400, which the router treats as a bad key/model and cools down for 5 minutes, so enable tools only with providers that support them.

## 5. Remote build flow

1. App generates a `correlation_id`, dispatches the workflow with it as an input.
2. Workflow sets `run-name: build ${{ inputs.correlation_id }}`, so the app can find its run (dispatch itself returns 204 with **no run ID**).
3. `BuildPoller` polls the run list → run → artifacts and emits states; the chat shows a progress card, then a download card.
4. Artifacts download as a **ZIP** (the APK is inside). The poller handles the redirect without leaking your token to blob storage, and the app unzips it.
5. Caveats: release APKs must be signed (store keystore in Actions secrets, or sideload a debug-signed build); artifacts expire (default 90 days); private-repo Actions minutes count against the user's quota.

## 6. Security notes (important)

- **GitHub PAT:** use a fine-grained token scoped to specific repos: Contents R/W, Actions R/W, Metadata R. Never log it. Store in secure storage only.
- **LAN proxy:** it spends the user's provider keys for anyone holding the bearer token. Generate a random 32-byte token by default, bind to loopback unless LAN is enabled, show a warning when enabling LAN, and never expose it to the internet. Traffic is cleartext HTTP on the LAN.
- **Mid-stream fallback is impossible without duplicating output.** The router only fails over *before the first token*. After that it surfaces the error (UI offers "Retry on next provider").
- **Free tiers:** OmniRoute explicitly frames itself as personal experimentation; each provider's ToS still applies to traffic you route.

## 7. Status of the code

Written against current APIs from memory and **not compiled or run** (no Flutter toolchain in my sandbox). Expect small fixes, especially the SAF package calls — check `saf_util` / `saf_stream` signatures against the pub.dev version you install. The `LocalFileService` interface is deliberately thin so you can swap in a MethodChannel if needed.

## Update: zero-setup routing, Manus-style chat

- `lib/services/default_providers.dart` hardcodes **OmniRoute** then **OmniRoute** as the
  built-in gateways (model `auto`). Override URLs/keys at build time with
  `--dart-define=OMNIROUTE_URL=... OMNIROUTE_KEY=... FREELLMAPI_URL=... FREELLMAPI_KEY=...`.
- `AppServices.rebuildChain()` always starts with those two; extra provider keys
  (Settings > Advanced > Extra providers) are optional fallbacks after them.
  `refreshGatewayModels()` reads `GET /models` from each gateway (5 s timeout, 60 s throttle) and
  exposes the results as pick-only endpoints (`Endpoint.selectableOnly`), which never join "auto".
- Model switcher lists `RouterService.available()`: configured and not cooling down.
- Chat header: menu, model pill, GitHub icon (opens connect/repo picker), overflow (new chat, build).
  Composer `+` sheet: upload file, upload photo, skill toggles, manage skills.
- Side drawer: chats, Skills, Connectors (GitHub, workspace folder), Settings.
- Skills (`skill_store.dart`) are appended to the system prompt while enabled.
- Inference parameters (temperature, top-p, max tokens, context size) are no longer exposed.
- Theme: text theme now follows brightness and `onSurface`/`onSurfaceVariant` are set explicitly.

## Update: composer features and background connectors

- Chat: empty-state suggestion chips, mic button (`speech_to_text`, needs RECORD_AUDIO, added by `patch_android.py`),
  copy button under every finished assistant reply. File/photo attachment already lives in the `+` sheet.
- `lib/services/telegram_bridge.dart`: Telegram Bot API long polling, answers only the chat you approve,
  holds the foreground service via `KeepAlive`, resumes on app launch. Token in secure storage.
- Connectors screen: Telegram section and a battery-optimization exemption button.
- NOT implemented: email (IMAP/SMTP), WhatsApp, browser automation. Not compiled or run (no Flutter toolchain here).

## Update: browser automation + photo fix

- `services/browser_session.dart`: one WebView kept mounted by `BrowserHost` (wraps MaterialApp child; 1px hidden, 45% panel when shown). http/https only.
- `services/agent/browser_tools.dart`: browser_open/read/click/type/scroll/back/show. Elements are numbered via a `data-ah` attribute.
  Settings > Browser automation (default off) and "Ask before each browser action" (default on).
- Router: a 400 on a request containing photos no longer cools the provider down for 5 minutes (text-only models reject images).
- Photos are sent as `image_url` parts, so they only work with vision-capable models. Pick one in the model pill if Auto fails.
- webview_flutter on Android may need `minSdk 21+` (already >= 23).

## Update: Terminal v2 (real shell, git, jobs) + Apple-style UI

**Why:** the old terminal was a ~20-command simulator (everything else returned exit 127), with no network, no git, a 60 s cap, and a separate file world.

| Blocker | Fix in code |
|---|---|
| No real shell | `terminal_bridge.dart` runs `/system/bin/sh` (toybox) in the app sandbox: pipes, redirects, `&&`, loops, scripts. Old simulator kept as `terminal_legacy.dart` fallback (iOS). |
| No git | `git_lite.dart`: clone (zipball), status, diff, commit, push (one atomic Git Data API commit), pull (conflict-aware), log, branch, checkout, reset. Token never reaches the model. |
| No network | `curl` / `wget` built-ins via `http_runner.dart` (any method, headers, body, `-o`). Auth header is never forwarded on cross-host redirects. |
| `browser_http_test` had no headers | Now shares `HttpRunner`: `headers`, all methods, `{{secret:github}}` placeholder, auto-auth for `api.github.com`; token redacted from output. New `http_request` tool does the same. |
| No toolchain | Not possible on a phone (no JDK/Gradle/Node). The agent is told to push and run GitHub Actions instead; error 127 prints that hint. |
| 60 s cap | `terminal_run` up to 600 s, plus `terminal_job_start / poll / kill / list` (log file backed, max 4 jobs). Jobs die if Android kills the app. |
| /workspace vs /storage islands | `/storage` maps to `/storage/emulated/0` when "Phone storage in terminal" is on (needs All-files access). |
| No `which`/`env` | `which` knows built-ins; `env` is the shell's. |
| Interactive prompts | stdin is closed, `GIT_TERMINAL_PROMPT=0`, `CI=true`. |
| Persistence | `/workspace` lives in the app documents dir and survives restarts (shown in the Terminal screen). |

Built-ins (`git curl wget unzip zip tar jobs which`) run as their own command, or chained with `&&`, `;`, `||`, and may feed a pipe (`curl ... | head`). They do not run inside scripts/loops/subshells; `$root/bin` shims explain this.

UI: `core/ios_widgets.dart` (large-title page, inset grouped sections, icon badges, CupertinoSwitch, sliding segmented control, action sheets). Settings, API Keys and Terminal screens use it. Connectors, Skills, Proxy and GitHub screens still use the older Glass style.

Not compiled: no Flutter toolchain was available. Run `flutter pub get && flutter analyze` first.


## Update: agent v3 (verify loop, plan card, memory, preview, undo, silent terminal)

| Feature | Where | How it works |
|---|---|---|
| Auto-verify loop | `agent_tools.dart` (`_commit`, `_startBuild`, `_afterBuild`, `get_build_logs`), `build_poller.dart` (`failureDigest`, `trimLog`, `BuildTracker`), `agent_runner.dart` (`ToolResult.settle`) | `commit_changes` pushes, dispatches the workflow, shows the live card and WAITS. On failure the failed job/step and a trimmed log go back to the model, which fixes and commits again. Max 3 failed builds per request, then it must stop and explain. Setting: Auto-verify builds. |
| Plan card | `plan.dart` (`update_plan`), `features/chat/plan_card.dart` | Pure UI tool. One card per run, replaced in place by each snapshot (pending / active / done / failed). |
| Project memory | `AgentWorkspace.beginRun`, `remember` tool | `AGENTS.md` is read at the start of every run and added to the system prompt (8 KB cap). `remember` stages one-line notes; if the file is missing the agent is told to create it. |
| Live preview | `preview_tools.dart` (`preview_html`), `deliverable_card.dart`, `deliverables.dart` (`PreviewReports`), `agent_runner.dart` (`notices`) | Builds a single page from repo files including STAGED edits (local css/js/small images inlined). Card has Reload, Full screen and a JavaScript error banner. The card reports page load and JS errors to `PreviewReports`; `preview_html` waits for that (`ToolResult.settle`, max 12 s) and returns the errors to the model, which fixes and previews again (max 2 retries). After load the page's visible buttons are auto-clicked once (max 12, risky-sounding ones and form submits skipped; `explore:false` turns it off), and optional `click` selectors are clicked in order (via `runJavaScript`), so errors behind interactions are returned too. It cannot type text or fill forms. Errors that appear later (user interaction) are queued and added to the next tool result or run by `AgentRunner.notices`. If the page never reports, the model is told it is unverified. |
| Undo | `Checkpoint`, `AgentWorkspace.checkpoint/restore`, `local_undo.dart` (`LocalUndoLog`, `UndoToolkit`), `AppServices.undo`, `_ToolRow` undo button, header menu "Undo points" | Repo: a snapshot of staged changes + branch head is taken before every mutating tool; restore resets staged files and, if commits were made since, force-moves the branch back, but only if nobody else pushed in between. Local files: `UndoToolkit` wraps the device-file and terminal toolkits and snapshots the touched paths (fs_* incl. fs_restore) or the whole `/workspace` plus the `/storage` paths the command names (terminal_run / terminal_job_start) before the call. Unchanged files are not copied again. Undo points are saved as JSON in the store (`index/`) and reloaded at startup, so they survive an app restart. Undo puts changed/deleted files back and moves files created since into `removed/` of the store (not deleted). A `git push` from the shell is recorded (`GitLite.onPush`, `PushRecord`); undo moves the branch back on GitHub if nobody pushed after it. `AppServices.undo` restores local side first, then the repo side, by time, so "later steps are undone too" holds across them. |
| Silent terminal | `terminal_tools.dart`, `settings_screen.dart` | Terminal screen removed. No tool row, no command text in the notification, and the model is told the user cannot see it. |

Cannot be undone, so the app asks first: HTTP POST/PUT/PATCH/DELETE (always asks, even with command confirmation off) and shell commands that build `/storage` paths at run time (variables, scripts, xargs, find -exec; asks when phone storage is on). Other limits: files over 1 GB or past 2 GB per snapshot are not backed up (undo reports how many); the store keeps at most 4 GB and drops the oldest undo points first; a copy can fail when the disk is full.
Not compiled: no Flutter toolchain here. Run `flutter pub get && flutter analyze` first.
