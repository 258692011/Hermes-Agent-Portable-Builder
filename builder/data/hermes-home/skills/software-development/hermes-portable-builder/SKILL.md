---
name: hermes-portable-builder
description: "Build relocatable Electron apps with bundled backends."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [windows]
metadata:
  hermes:
    tags: [electron, packaging, portable, backend, windows]
    category: software-development
---

# Hermes Portable Builder Skill

Use this skill to research or implement relocatable Electron distributions, especially applications that launch a Python or other native backend. It distinguishes a packaged Electron shell from a genuinely self-contained portable application and emphasizes runtime path resolution, writable-state isolation, native dependency staging, and clean-machine verification.

This is a user-project skill for the Hermes Portable Builder, not an official bundled Hermes skill. Its canonical skill source is `D:\Hermes-Agent-Portable-Builder\builder\data\hermes-home\skills\software-development\hermes-portable-builder`, while build-only implementation lives separately under `builder`. Releases install this skill tree under `<portable-root>\data\hermes-home\skills\software-development\hermes-portable-builder`; executable maintenance helpers live once under `<portable-root>\scripts`.

## Project Release Contract

- Keep release docs and code aligned: when an entry point, artifact, runtime, or maintenance behavior changes, update `README.txt`, templates, launchers, updater, build script, and every related reference in the same change.
- `runtime\bin\hermes-tui.cmd` is a thin CRLF wrapper around `hermes-cli.cmd` (`call "%~dp0hermes-cli.cmd" --tui %*`, then `exit /b %errorlevel%`). It sets `HERMES_TUI_NO_EARLY_DISABLE=1` (upstream escape hatch in `hermes_cli/main.py::_suppress_mouse_residue_early`) because that function writes the DEC mouse-mode reset CSI batch via `os.write` before the console's VT processing is enabled — legacy cmd/conhost prints those bytes as literal garbage. `runtime\bin\hermes-dashboard.cmd` is a second thin CRLF wrapper that opens the web dashboard (`call "%~dp0hermes-cli.cmd" dashboard %*`): it parses `--port N` / `--port=N` (default 9119; edit the `PORT` line for a fixed port, `--port 0` skips the check and lets the server auto-assign), checks `netstat -ano | findstr :<port> | findstr LISTENING` and, if the dashboard server is already up, just `start "" http://127.0.0.1:<port>` and exits — otherwise it starts the server (foreground, auto-opens the browser; closing the window stops it). PITFALL: `shift` overwrites `%0` (the script path) with the first argument, so `%~dp0` resolves to the current directory after any `shift` — capture `set "BIN=%~dp0"` BEFORE the arg-parsing loop and call `"%BIN%hermes-cli.cmd"` after it. Keep ALL environment logic in `hermes-cli.cmd` only (it clears the desktop-app-leaked `HERMES_WEB_DIST` so a standalone `hermes dashboard` serves the shipped `hermes_cli/web_dist` browser UI instead of the Electron bundle, which needs the desktop IPC bridge and breaks in a plain browser), and ship all THREE entry points together in every build and deployed copy (root, all drives, builder template) plus the `README.txt` 故障排查 entry.
- Ship a prebuilt TUI bundle at `hermes_cli/tui_dist/entry.js` (build: `npm install --workspace ui-tui --include=dev --silent --no-fund --no-audit --progress=false` from the repo root, then `npm run build` inside `ui-tui/`, then copy `ui-tui/dist/entry.js` there). Without it the first `hermes --tui` launch runs an npm install at runtime (slow, network-dependent, and after desktop-sync cache cleanup it will always be missing); with it, launch is instant and offline. Rebuild the bundle after every source update — a stale bundle breaks the TUI↔backend protocol — by adding the step to BOTH the packaging script (fatal) and the desktop-sync helper (non-fatal: on failure delete the stale bundle so the TUI falls back to a first-launch install). The desktop-sync cleanup that removes repo `node_modules` is safe only while `tui_dist` exists.
- Ship a prebuilt web bundle the same way: `npm install --workspace web --include=dev --silent --no-fund --no-audit --progress=false` from the repo root, then `npm run build` inside `web/` (vite `outDir` is `../hermes_cli/web_dist`, so no copy step is needed). Pin the working directory for the INSTALL step too (`Push-Location $Repo` around it, mirroring the TUI step) — `npm install --workspace web` resolves the workspace root from cwd, and running it from an unpinned cwd fails with exit code -4058 (ENOENT, npm cannot find package.json) whenever the caller's cwd is outside the repo; the TUI step already pins cwd, the web step originally did not (verified 2026-08: build #1 passed because the shell cwd happened to be the upstream repo, build #2 failed). AND write the web UI build stamp (`$HERMES_HOME/web-ui-build-stamp.json`, content hash of web/ source) using the same code that reads it — `hermes_cli.main._write_web_ui_build_stamp(repo, repo/'web')` via the staged venv — otherwise `_web_ui_build_needed()` is True on first launch and `hermes dashboard` runs a runtime `npm install --workspace web --prefer-offline` (network-dependent, same failure class as the TUI bundle). In the packaging script the stamp step is fatal (after `Install-PortableVenv`, run with `$env:HERMES_HOME` + `PYTHONPATH` pointed at the staged checkout); in the desktop-sync helper it is non-fatal (a missing stamp only costs one rebuild — never delete a good `web_dist` because the stamp failed). Also add `-e hermes_cli/web_dist/` to every staged `git clean -fdx` (web_dist is gitignored upstream) so the prebuilt bundle survives the clean. PITFALL (verified 2026-08, two failed builds): the stamp MUST be the last step that can change its hashed inputs (web/ + package.json + package-lock.json) — i.e. place it right before the archive step. There are TWO staged git resets in Build-Hermes-Portable.ps1: the first (`git reset --hard` after copy) does NOT rewrite files — robocopy preserved mtimes, git's stat cache skips the rewrite, and the tree keeps CRLF bytes; only the later `git rm -r --cached` + `reset --hard` (the documented line-ending fix) rewrites every tracked file to LF. A stamp written before that second reset hashes CRLF content: `_web_ui_build_needed()` returns True on the user's first launch and `hermes dashboard` runs a runtime npm install + rebuild. Symptom: staged `_web_ui_build_needed` = True while the stamp exists; web/ file mtimes AFTER the stamp's builtAt timestamp prove the second reset rewrote them later.
- Treat official `scripts\install.ps1` `$PythonVersion` as the only Portable Python selector. Build and update paths parse it; `hermes-cli.cmd` reads only `runtime\python\current.txt` and never hard-codes a patch directory.
- Do not read a previous Portable or any runtime-seed environment variable. Every build creates a fresh runtime tree: copy suitable system uv/Node/full Git for Windows when present, otherwise download them; always provision isolated Python and a fresh locked venv under `build`.
- The current release target is Windows x64 only. Reject other architectures before download/build; pin uv (since 2026-08-09 no separate SHA256 check: the archive's own CRC fails corrupt downloads at extraction, HTTPS + 3x retry covers transient failures — the `.sha256` fetch/verify path was removed from `Install-ManagedUv` and the cached `.sha256` file deleted); sync dependencies with `--no-install-project --link-mode copy` so no editable build-root mapping enters the venv.
- Keep the build-project skill and active profile skill aligned after workflow changes. Never copy the build overlay into the official checkout or release root. Release only `SKILL.md` plus `references\` as the user skill, and keep executable maintenance helpers uniquely under `<portable-root>\scripts`.
- In a packaged Portable, invoke maintenance helpers from `<portable-root>\scripts\Update-Portable.ps1` (stages: `Patch`, `PatchRemove`, `SyncDesktop`), `Repair-Portable.ps1` (self-contained no-arg repair entry, moved out of Update-Portable.ps1 2026-08-10), or `Verify-Portable.ps1`; do not expect skill-local scripts/templates/assets.
- When TESTING any maintenance script that can kill processes (Repair-Portable.ps1 without `-KeepProcesses`, Update-Portable.ps1 SyncDesktop, Update.exe), ALWAYS pass `-KeepProcesses` or use a read-only mode (`-ShowOfficialPythonVersion`). The LIVE Hermes desktop app under the deployed root was killed mid-session on 2026-08-10 by a no-arg test run of the then-new self-contained Repair-Portable.ps1: its default behavior (no `-KeepProcesses`) runs Stop-RootProcesses, killing every Hermes.exe/python.exe under the portable root — the desktop app crashed out from under the user mid-conversation (repair work itself was intact). Test on the deployed copy only with process-preserving flags and verify the Hermes processes survived afterward.
- Prefer bounded, high-signal verification. If a test/install path repeatedly fails or becomes disproportionate, stop, remove its generated files/installations, fix the root workflow, and rerun only the relevant gate.
- Build-log hygiene: long background builds must redirect stdout/stderr to `builder\logs\build-YYYYMMDD-HHMMSS.log` (create the dir if missing); never write build-log files to the builder root. The log is evidence for the final report (quote real exit code / artifact names), not a deliverable — stale logs in `builder\logs\` may be pruned after a successful build. Run the wrapper with `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; & '<script>'"` (instead of `-File`) so npm/vite's UTF-8 box-drawing output survives the PS 5.1 GBK console pipeline — without it, multibyte chars are written into the log already corrupted (`E2 94 82` → `E2 94 3F`, observed 2026-08-10).
- Do not create or discuss checksum sidecars unless the release contract or user explicitly requests them; verify archive integrity directly otherwise.

## Self-Improvement Contract (mandatory)

Whenever you make a mistake while working on this project and then find the correct approach, **update this skill immediately in the same session** — do not wait to be asked, do not defer to a later task. This skill is the project's institutional memory; every error-to-fix cycle that is not written back is a lesson the next run will re-pay.

Trigger: you hit an error, a wrong assumption, a failed command, a user correction, or a rework — AND you then found the approach that actually worked. Typical examples from this project: bash↔PowerShell quoting (`$var` expansion), MSYS path handling for native tools, CRLF/EOL traps, PowerShell 5.1 `NativeCommandError`/pipeline pitfalls, exit-code masking, dependency-layout assumptions, staged-clean/`git reset` ordering.

How to record:

1. **Where**: add a dated pitfall (`observed YYYY-MM-DD`) to the main `SKILL.md` Pitfalls section, or to the matching appendix in `references/hermes-agent-windows-portable.md` when it is a reference-level detail. Update the main SKILL.md with a short pointer line when the detail lives in the reference.
2. **What**: symptom (exact error/behavior), root cause, the proven correct approach, and a one-line verification note. Name real files/line numbers where useful.
3. **Both copies**: the skill ships twice — `builder\data\hermes-home\skills\software-development\hermes-portable-builder\` (canonical source) and the active profile copy (`<portable-root>\data\hermes-home\skills\...`, what Hermes actually loads). Patch the builder copy, copy both files to the profile copy, and verify `diff` reports them byte-identical before finishing.
4. **Scope**: record only lessons that would save time if the same mistake recurs (project-specific, non-trivial, cost real time). Do not record one-off trivia, task progress, or anything stale in a week. When unsure whether a lesson is worth recording, record it — a concise pitfall is cheap; re-learning the mistake is not.
5. **Report**: in the final reply, state what was added and that both copies are in sync.

## Upstream Sync (mandatory every build)

Before every build, sync `upstream/` to exactly mirror `origin/main`:

```powershell
git -C <builder-root>\upstream fetch --prune origin
git -C <builder-root>\upstream reset --hard origin/main
```

`upstream/` is a read-only official checkout. `reset --hard` guarantees a byte-exact mirror. The build script will apply and remove its own portable patch; unrelated local modifications must not survive.

## Build Trigger Rule (user-controlled)

Only start a full build (`Build-Hermes-Portable.ps1`) when the user says to build (e.g. "构建/重新构建/打包"). Do not infer a build from status statements, questions, upstream commits, seed changes, or earlier requests. When in doubt, ask.

## When to Use

- Auditing an Electron app's installer, unpacked build, or portable target.
- Bundling a Python, Node, Rust, or native service behind Electron.
- Converting an installed application into a directory-based portable ZIP.
- Diagnosing why a package builds successfully but fails on a clean machine.
- Reviewing electron-builder hooks, `extraResources`, ASAR boundaries, or native modules.
- Determining where application state, Electron `userData`, logs, and backend state are written.
- Diagnosing `hermes dashboard` failures: "Desktop IPC bridge is unavailable." toast, wrong frontend served, missing/stale web UI (`hermes_cli/web_dist`) — see the Web Dashboard section below.

## Prerequisites

- Read the repository's root and app-scoped contributor instructions.
- Inspect the root workspace manifest and the Electron app manifest.
- Identify the exact branch and commit researched; packaging logic changes quickly.
- Use repository source as authority. README build commands alone do not prove what is bundled.
- For implementation work, have a clean or sandboxed machine/profile available for verification.

## How to Run

For research-only work:

1. Pin the repository branch and record the resolved commit.
2. Read the app README, scoped `AGENTS.md`, root `package.json`, app `package.json`, and packaging scripts.
3. Trace Electron main-process path resolution and the child-process spawn environment.
4. Distinguish build-time payload staging from first-launch bootstrap installation.
5. Report the minimal portability changes, exact build commands, and pitfalls without modifying the upstream repository.

For implementation work, additionally build an unpacked directory first, populate runtime payloads, launch from multiple paths, and only then archive it.

## Quick Reference

A distribution is not genuinely portable unless all of these are controlled:

| Concern | Portable requirement |
|---|---|
| Electron files | Shipped in unpacked directory or archive |
| Backend executable/runtime | Bundled and relocatable |
| Backend code/dependencies | Bundled, not fetched on first launch |
| Application state | Written beneath a stable portable data root |
| Electron `userData` | Redirected before paths derived from it are computed |
| Native modules | Built/staged for exact target platform and architecture |
| Updates | Disabled or redirected away from read-only packaged resources |
| Verification | Tested without system runtime, PATH shims, or pre-existing user state |

Directory-based ZIP portability is usually safer than a single-file portable executable when the app carries a large runtime. Single-file targets commonly self-extract to a temporary directory, making `resourcesPath` unsuitable as a persistent data root.

## Procedure

### 1. Establish the packaging graph

Trace the scripts behind `build`, `pack`, `dist`, and platform-specific targets. Include lifecycle hooks such as:

- `prebuild` / `postbuild`
- electron-builder `beforeBuild`
- `beforePack` / `afterPack`
- `afterSign`
- custom wrappers around electron-builder

Record which step builds renderer assets, bundles the main process, stages native dependencies, writes build metadata, and creates installers.

### 2. Prove what is actually shipped

Inspect:

- `build.files`
- `extraResources`
- `asar` and `asarUnpack`
- any hook that returns `false` to skip dependency collection
- payload-copy scripts
- first-launch installer/bootstrap code

Do not infer backend bundling from product copy such as "installer handles Python." Determine whether the runtime is physically in the artifact or downloaded after launch.

### 3. Trace writable roots

Find every root used for:

- domain state/configuration
- Electron `userData`
- caches and logs
- backend source/install tree
- virtual environments
- updater metadata
- connection/profile state

Environment variables or command-line overrides must be applied before module-level constants or `app.getPath('userData')`-derived paths are initialized. Redirecting only the backend home is insufficient if Electron still writes state to AppData, Library, or XDG locations.

### 4. Trace backend resolution as an ordered ladder

Document each candidate in precedence order and its validation probe. Typical rungs are:

1. explicit source/runtime override
2. development checkout
3. managed application install
4. command override or PATH command
5. system interpreter/module
6. first-launch bootstrap

Existence is not validity. Verify imports, version/help commands, architecture, and required modules before selecting a candidate. Also trace compatibility command rewrites for older backend versions.

### 5. Trace the spawn contract

Capture:

- executable
- argv
- working directory
- environment merge order
- `PATH` and language/runtime search paths
- hidden-window flags on Windows
- readiness protocol
- shutdown and updater ownership

A portable patch should reuse the app's canonical backend command builder rather than introducing a second launch path.

### 6. Choose the minimum viable portable shape

Prefer this order:

1. **Launcher-only prototype:** set existing supported path overrides before starting the app.
2. **Native portable mode:** derive paths from the executable directory early in Electron startup.
3. **Packaging integration:** add backend/runtime payloads through `extraResources` or a post-pack staging step.
4. **Custom updater model:** only if the packaged backend must remain mutable.

A practical layout is:

```text
App-Portable/
├─ App.exe
├─ resources/
│  ├─ app.asar
│  ├─ backend/
│  └─ runtime/
├─ data/
│  ├─ app-home/
│  └─ electron-user-data/
└─ Portable launcher
```

Keep runtime resources read-only and all mutable state beneath `data/`.

### 7. Make the backend relocatable

Ordinary Python virtual environments are not automatically relocatable. Audit:

- `pyvenv.cfg`
- generated console-script launchers
- editable-install `.pth` files
- absolute paths in metadata/configuration
- native wheels and DLL search paths

On Windows, treat a tool's `--relocatable` venv flag as a hypothesis, not proof. A launcher may still be a trampoline that records the build-time interpreter path. Renaming the parent directory is the decisive test. Re-running venv creation with `--allow-existing` may refresh launchers but also sever or replace package associations, so verify imports afterward rather than assuming repair succeeded.

The robust fallback is a relative-path wrapper that:

1. derives the portable root from `%~dp0` or the executable directory;
2. locates the bundled CPython under that root;
3. prepends a bundled `sitecustomize.py` bootstrap and the backend source to `PYTHONPATH`; the bootstrap calls `site.addsitedir()` on the retained `site-packages` directory so `.pth` hooks and pywin32 DLL setup still run after relocation;
4. invokes `python.exe -m package.module %*` directly;
5. is selected through the application's existing explicit backend-command override.

Prefer this direct interpreter/module path over generated console-script shims. Avoid editable installs that point back to the build checkout.

### 8. Deduplicate managed runtimes using the upstream provisioning contract

Before archiving, enumerate the immediate children of every managed-runtime root and flag overlapping interpreters such as both a minor-series directory and an exact-patch directory. Do not decide which copy to retain merely from the current venv's `pyvenv.cfg`: that file may point at whichever duplicate happened to be selected during an earlier staging or relocation repair.

Use this order of authority:

1. inspect the upstream installer and record the version selector passed to the runtime manager;
2. ask the runtime manager which concrete interpreter that selector resolves to;
3. identify its canonical managed-directory name from real install output/inventory;
4. retain that canonical directory, rebuild the venv against it, then update every launcher and repair script to the exact retained path;
5. prove the removed directory is unreferenced and run interpreter version, core imports, venv repair, backend readiness, Desktop startup, move/relaunch, and archive-inventory checks.

For uv-managed CPython, an upstream request such as `uv python install 3.11` resolves to a concrete patch release, but the managed directory name is not a reliable version oracle: depending on uv state and install mode, Python 3.11.15 may appear under either an exact directory (`cpython-3.11.15-windows-x86_64-none`) or a minor-series alias (`cpython-3.11-windows-x86_64-none`). Determine identity from `uv python find 3.11 --managed-python` plus the selected `python.exe --version`, not from the directory name alone. For an initial release, retain the one upstream-resolved, validated directory and rebuild the venv against it rather than preserving an accidental old venv reference.

Avoid wildcard runtime selection at application launch (`cpython-*...`): enumeration order can silently switch interpreters when an update temporarily leaves multiple versions. Store the validated active **exact directory** name in `runtime/python/current.txt`; the launcher reads only that pointer.

For projects that must follow upstream's default Python completely, treat the upstream Windows installer's top-level `$PythonVersion = "X.Y"` as the sole version-selection authority. Do **not** use `requires-python` to choose or veto that default: it describes a compatibility range, not the interpreter upstream intends to provision. After updating source, parse `$PythonVersion`, run `uv python install/find <X.Y>`, and let locked dependency sync plus core-import smoke tests decide whether cutover succeeds. Portable launchers must read only the updater-maintained `runtime/python/current.txt`; they must not hard-code an exact patch directory as fallback, because a future upstream update may change `$PythonVersion`.

uv may create both an exact physical directory (`cpython-3.12.13-...`) and a minor-series junction (`cpython-3.12-...` pointing to it). These are one runtime, not duplicates. Resolve the junction target and write the exact directory to `current.txt`, but retain the active junction when the venv's `pyvenv.cfg` references it. Prune only old physical directories and aliases that do not target the active exact directory.

During explicit update, back up the current Python directory itself as well as the venv and pointer. Build and smoke-test the replacement venv before cutover; on failure restore old Python, venv, and pointer. Ordinary startup remains offline and reads only the validated pointer.

When editing CRLF Windows batch launchers, read the resulting file back before execution: targeted patch engines can mis-handle backslash sequences such as `\r` and split a path like `runtime` across lines. For a short launcher, prefer a complete rewrite with explicit CRLF, then execute a harmless `--version` probe. See the `Windows managed-python dedup` and `uv-managed Python portable updates` appendices in `references/hermes-agent-windows-portable.md` for the audit/acceptance recipe and the update transaction.

### 9. Stage target-native dependencies

Host architecture is not necessarily target architecture. Packaging hooks that receive the real target platform/architecture should restage and validate native modules immediately before packing. Check `.node`, DLL, helper executable, and prebuild payloads by binary format where possible.

When compiling Windows launcher or updater executables outside electron-builder, embed the application's authoritative Windows icon at compile time. For Hermes Portable, use `apps/desktop/assets/icon.ico` for both root entry points, `Hermes.exe` and `Update.exe`, via the compiler's `/win32icon:<path>` option. Do not rely on the inner Electron executable, a shortcut, or Explorer cache to supply the root launchers' icons. Fail the build if the official icon is missing, then inspect each generated PE for an icon group/resource before archiving.

Give every Portable archive a collision-free local build timestamp after the platform suffix. Use `Hermes-Agent-Desktop-Portable-<version>-win-x64-yyyyMMdd-HHmmss.zip`, based on the builder's local time at archive creation. Do not overwrite or ambiguously reuse an older artifact with the same Hermes version; validate the timestamped filename as part of release inventory checks.

### 9. Build unpacked first

Generate the complete `build` target before creating an installer or archive. Add the portable runtime and data layout, compile the launchers, then run all release gates against that exact staging tree. Archive only after those gates succeed.

For this Hermes Portable workflow, staging is the authoritative test surface. Before compression, verify the Python contract, component/import probes, embedded checkout cleanliness, official launcher icons, timestamped output name, README/entry-point contract, and skill presence/content. Because compression does not transform file payloads, do not routinely extract the just-created ZIP and rerun the same functional suite; that duplicates a long test without improving the compiled artifact. Post-archive verification is limited to archive integrity plus inventory checks for required/forbidden paths. Perform an extraction test only when archive/extraction semantics themselves changed, when investigating corruption, or when the user explicitly requests it.

### 10. Verify portability

Test from:

- a short ASCII path
- a path containing spaces
- a Unicode path
- a deeper directory
- a clean user profile or sandbox

Confirm:

- the backend starts and announces readiness
- no system Python/runtime is used
- no download/bootstrap occurs
- no state is written outside the portable root
- restart preserves state
- native terminal/process functionality works
- moving the whole directory does not break imports or launchers

### 11. Design and test the updater as part of portability

A runtime wrapper that successfully launches a moved application does not prove that an upstream self-updater is portable. Trace the updater's dependency-install target separately. In particular, check whether it:

- exports `VIRTUAL_ENV` to a retained venv whose Windows trampoline embeds the build path;
- invokes generated console-script shims rather than the relative runtime wrapper;
- creates an interrupted-update marker before dependency installation;
- mutates the Git checkout or rebuilds Electron while Desktop/backend processes still hold files;
- falls back from Git to ZIP but then repeats the same broken dependency-install step;
- reports success only after imports, backend readiness, and any Desktop rebuild are verified.

For a directory Portable build that bypasses venv launchers at runtime, the updater must use the same bundled CPython and relative dependency payload strategy, or deliberately recreate a healthy install target before calling the official updater. Stop all processes beneath the portable root first. Preserve `data/`, take a verified backup, and test the update from a moved directory—not just the original build path.

A robust Windows update chain has five explicit phases:

1. **Preflight/repair:** probe the retained venv by importing core modules. Treat probe stderr and nonzero exit as an unhealthy venv, not as a PowerShell-terminating exception. Recreate it with bundled CPython plus locked dependencies; preserve the old venv until imports pass.
2. **Clean-checkout preparation:** remove only the marker-bounded generated Portable source patch before invoking upstream. The embedded Git checkout must retain every tracked source file and report both `git status --porcelain` = empty and `git stash list` = empty. Deleting tracked Desktop/docs/build sources to shrink the archive creates thousands of apparent local deletions and triggers updater autostash prompts even when the Portable patch itself is absent. On Windows set repository-local `core.longpaths=true`, `core.autocrlf=false`, and `core.eol=lf`; restore a damaged checkout with a short temporary `subst` path when necessary.
3. **Official source update:** invoke the upstream updater from the repaired venv and require its terminal success state. A network failure is distinct from a runtime-repair failure. A prompt such as `Restore local changes now? [Y/n]` means preflight did not achieve a clean checkout; fix the packaged checkout rather than automating an answer.
4. **Portable Desktop rebuild/sync:** reapply the bounded early portable-path patch to the freshly updated Electron source, build `win-unpacked`, validate `Hermes.exe`, stage a complete `app.portable-next`, then atomically swap it with the live `app` while retaining rollback material. Patch apply/remove must be idempotent; remove (`-Stage PatchRemove`) should succeed when the patch or Desktop source is already absent. Since 2026-08-08 the sync stage self-cleans: after the swap it runs the patch-remove stage itself, so the embedded checkout is pristine when the script exits and a direct `hermes update` (outside Update.exe) never hits the "Restore local changes now? [Y/n]" stash prompt; Update.exe's own pre-update `-Stage PatchRemove` (and its `git clean -fd`) remains as a safety net for patches from other sources. The three update-chain scripts (repair / patch / sync) were merged into one `<portable-root>\scripts\Update-Portable.ps1` with `-Stage Repair|Patch|PatchRemove|SyncDesktop` on 2026-08-10.
5. **Cleanup/verification:** remove the generated source patch again before archiving the next release, launch the replaced Desktop directly, confirm the embedded backend listens on loopback, remove interruption markers and rollback trees, then remove only untracked/ignored build caches (`node_modules`, `release`, `dist`) after the live app owns the artifact.

When a PowerShell 5.1 helper edits UTF-8 source, use `[System.IO.File]::ReadAllText(..., [Text.Encoding]::UTF8)` and write UTF-8 without BOM. Plain `Get-Content -Raw` can decode non-ASCII comments incorrectly and corrupt an otherwise valid TypeScript file. Before rebuilding, check that the patch changes only its bounded marker block (for example via `git diff --numstat` and `git diff --check`).

Do not ship an `Update.cmd` merely because `hermes update` exists. Run it end to end against an available upstream change or a controlled broken-trampoline fixture, inspect its log to the terminal success marker, restart Desktop, and verify the new commit/version and backend readiness. A Git pull or ZIP extraction followed by dependency failure is an incomplete update even when the old wrapper can still launch the app.

See `references/hermes-agent-windows-portable.md` for the Hermes-specific broken-trampoline/update-marker failure mode and acceptance checks.

### 12. Customize first-run UI defaults without breaking user persistence

Treat a requested "default" as a first-run seed, not a value to force on every launch. Before rebuilding:

1. inspect the upstream default and distinguish it from the runtime/browser baseline (for Electron zoom, Chromium actual size is 100% while the app may intentionally ship another preset);
2. report that distinction before committing to a requested replacement when it could change the user's choice;
3. trace the app's canonical persistence path and restore order (main-process JSON, renderer localStorage, IPC, window lifecycle events);
4. change the app-level default through a bounded, removable build patch and update the directly corresponding tests;
5. preserve saved user values on later launches and verify that a manual change survives restart;
6. remove the source patch before archiving while retaining the compiled behavior in the packaged app.

For Chromium zoom, convert user percent `p` to Electron zoom level with `log(p / 100) / log(1.2)` and verify the round trip through the application's own IPC rather than inferring from file contents. A correct `zoom-state.json` does not prove the active window kept that zoom: Chromium may reset the window after an early restore. If that occurs, reassert the persisted value after the packaged window's initialization settles; re-read the saved value rather than hard-coding the requested default, so later user choices still win.

When testing Portable path behavior, launch through the real Portable launcher or reproduce its environment exactly. Directly starting `app/App.exe` may bypass launcher-set home/userData overrides unless compiled native portable-mode detection is independently verified. Check `app.getPath('userData')` or the observed state-file location before drawing conclusions from a runtime probe.

See the `Electron first-run defaults` appendix in `references/hermes-agent-windows-portable.md` for a concise zoom/onboarding verification recipe.

### 13. Sanitize release state before archiving

Never archive from a staging tree after it has been launched without resetting its writable data roots. A smoke test can silently seed onboarding completion, skipped-provider flags, sessions, credentials, memories, logs, caches, and SQLite state into the release.

For a fresh-user Portable ZIP:

1. stop every process whose executable is beneath the staging root;
2. empty Electron `userData` completely (retain only the empty directory);
3. remove backend user state such as `.env`, `auth.json`, `state.db*`, sessions, logs, memories, caches, snapshots, profiles, pairing state, and user-created skills/plugins unless the distribution explicitly intends to seed them. **Intentional seeds as of 2026-08-12:** `builder\data\hermes-home\memories\USER.md` (user-profile seed, copied as-is into `data\hermes-home\memories` via the single `builder\data` → `data` `Copy-Tree` block — the builder's `data\` tree mirrors the shipped `data\` layout, so anything added under `builder\data` ships as-is) is an explicit distribution seed and must NOT be removed by this step. Do not add `MEMORY.md` (agent personal notes) as a seed — it carries build-machine-specific state (DNS/hosts diagnostics, project-internal records) that must not ship to every user. The `hermes-portable-builder` user-skill presence/slim gates were removed from `Test-PortablePythonContract` on 2026-08-12 at the user's request (skills are now optional in the release); the remaining skill-related gate (`git ls-files` overlay check in the embedded official checkout) stays.
4. retain only required runtimes/source plus a minimal non-secret default config (for example, a language default). For Hermes Agent Desktop Portable, seed exactly `data/hermes-home/config.yaml` with `display.language: zh`; do not change upstream `DEFAULT_LOCALE`, because the Portable distribution default must remain a first-run config seed and later user language choices must persist;
5. audit the archive inventory for forbidden state after packaging;
6. validate onboarding from a disposable extraction, then discard that extraction—do not rearchive the launched fixture.

Do not infer a removed onboarding screen from a returning-user launch. Inspect the app's persisted first-run keys and test with empty `userData`. When screenshot capture is unavailable, use Electron CDP (`--remote-debugging-port`) to read `document.body.innerText` and assert the expected first-run copy.

### 14. Clean verification artifacts immediately

Treat extracted-archive smoke-test directories as disposable fixtures, not deliverables. After the final verification has been recorded:

1. stop processes whose executable paths are beneath each test root;
2. delete every extraction/relocation test directory in the same task;
3. verify each path no longer exists;
4. retain only the release archive, necessary source/build workspace, and any explicitly requested staging directory; retain a checksum sidecar only when it is part of the requested release contract.

Do not leave multiple same-named portable trees for the user to distinguish later. If Windows deletion leaves long-path remnants, shorten the root with a temporary `subst` drive, mirror an empty directory into the target with `robocopy /MIR`, remove the target, remove the temporary drive, and verify absence.

Routine builds should not create an extracted-archive fixture at all. When the exceptional extraction cases above apply, clean the fixture in the same task.

## Pitfalls

- A successful electron-builder run proves only that Electron packaging succeeded.
- An unpacked app can still depend on a system backend or online bootstrap.
- Redirecting the domain home but not Electron `userData` leaves a non-portable application.
- Computing portable paths after module-level constants initialize has no effect.
- Packaged resources may be read-only or replaced during updates; never store user data there.
- A single-file target may run from a temporary extraction directory.
- A normal venv or editable install often embeds build-machine paths.
- Adding retained `site-packages` directly to `PYTHONPATH` does not process its `.pth` files. On Windows, use a relative `sitecustomize.py` bootstrap with `site.addsitedir()` so pywin32 and MCP stdio remain importable.
- The current venv's interpreter path proves current wiring, not which managed-runtime directory is canonical. When deduplicating, inspect the upstream installer and runtime-manager resolution first. Treat an exact physical directory plus a minor-series junction targeting it as one runtime, not duplicate payloads.
- `requires-python` is a compatibility declaration, not the upstream default interpreter selector. When the goal is to follow upstream exactly, parse the installer's explicit `$PythonVersion` and validate the resulting environment through locked sync/import probes.
- Do not delete a uv minor-series junction merely because `current.txt` points at its exact target; Windows uv venv trampolines may still reference the junction recorded in `pyvenv.cfg`.
- Wildcard runtime discovery can select a different duplicate based on enumeration order; shipped launchers and repair scripts should target one verified exact runtime path.
- PATH resolution can accidentally select the desktop executable itself or a stale shim.
- Native dependencies must match the target, not merely the build host.
- Source-based self-update may try to mutate an embedded read-only checkout.
- A moved-runtime wrapper can work while the official updater still targets a broken retained venv; launch and update paths require separate relocation tests.
- PowerShell 5.1 source patchers must use explicit UTF-8 decoding; default `Get-Content` can mojibake non-ASCII comments and break bundling.
- Upstream `pyproject.toml [tool.uv]` may declare `override-dependencies` and a relative `exclude-newer` ("14 days", recorded in uv.lock as `exclude-newer-span`). Do NOT set `UV_NO_CONFIG=1` in repair helpers before `uv sync --locked`: it strips the whole `[tool.uv]` table, uv re-resolves without the project's resolution constraints, and `--locked` fails with "The lockfile at uv.lock needs to be updated" (or "unsatisfiable" when `exclude-newer-package` exemptions are lost). Project config beats any user uv.toml, so plain config discovery is safe. Reproduce/prove with `uv lock --check` (and a `uv sync --locked --dry-run`) under the exact helper env, with and without `UV_NO_CONFIG`.
- When a shipped repair helper hardcodes `UV_NO_CONFIG=1`, patch the helper template AND every deployed copy at once (they must stay byte-identical) and keep the deployed scripts in sync with the builder's `builder/scripts` sources; a venv can be healthy while `-UpdatePython` still fails, so verify the exact sync command passes, not just imports.
- A packaged venv created without `--relocatable` keeps `pyvenv.cfg home` pointing at the builder's build tree. A deployed copy's desktop backend then executes FROM `build\` (its venv trampoline re-execs the build-tree python), locking build-tree DLLs so the next build cannot remove/recreate the stage (`libcrypto-3-x64.dll` access denied during `Resolve-OrInstallPython`). Always create the portable venv with `uv venv --relocatable`; repair already-deployed copies with `Repair-Portable.ps1 -UpdatePython -KeepProcesses` and require an app restart so the backend detaches from the build tree before rebuilding.
- Run the builder from a sanitized environment: a leaked `UV_PYTHON_INSTALL_DIR` (inherited from a running portable) makes `uv python find <selector> --system` resolve to the LIVE portable's runtime python, whose DLLs are locked by the running backend, so the stage python copy fails. FIXED (2026-08-05): `Build-Hermes-Portable.ps1` opens by clearing any inherited `UV_PYTHON_INSTALL_DIR/BIN/REGISTRY` (with a "Sanitizing leaked ..." log line); `Install-ManagedPython` then re-sets all three to the stage's own `runtime\python` before invoking uv, so no external `env -u` is required anymore (harmless if still used). Keep only the desired node/git/System32/PowerShell dirs on PATH (a venv `Scripts` dir on PATH is another python-copy trap); an explicit PATH makes builder runs deterministic.
- The post-TUI-build lockfile-restore guard must be `& git.exe -C $Repo checkout -- package-lock.json` with an explicit `-C`: the TUI build's `Push-Location`/`Pop-Location` pairs leave the script cwd OUTSIDE the repo, so a bare `git checkout` fails with "fatal: not a git repository". In the update script the guard sits inside the TUI step's `try`, so the `catch` then treats the whole step as failed and DELETES the freshly built bundle (false-positive "stale" removal) — first TUI launch regresses to npm install. Check BOTH `Build-Hermes-Portable.ps1` and `Update-Portable.ps1` (SyncDesktop stage); they are separate occurrences of the same bug class.
- RESOLVED for the desktop: the portable launcher (`Hermes-Desktop.cs`) now sets `HERMES_DESKTOP_HERMES_ROOT=<root>\data\hermes-home\hermes-agent` (resolver rung 1) and `HERMES_DESKTOP_PYTHON=<root>\runtime\python\<current.txt dir>\python.exe`; the patch stage (`Update-Portable.ps1 -Stage Patch`) additionally replaces the `command =` line in BOTH `createPythonBackend` and `createActiveBackend` with a marker-bounded `portablePython ?? (...)` override so the bundled runtime python is used instead of the venv trampoline when `HERMES_DESKTOP_PYTHON` is set. Verified: with `pyvenv.cfg home` pointed at a nonexistent path (simulating an end-user machine), the packaged app's backend still starts from `runtime\python\...\python.exe` and reaches "Hermes backend is ready" — offline and relocatable. The patch round-trip must replace whole lines INCLUDING leading indentation (a substring needle leaves indent residue on remove); apply/remove must be byte-exact (`git status --porcelain` empty after remove).
- Interrupted git operations can leave `tmp_pack_*` files in the packaged checkout's `.git\objects\pack\` that inflate the archive by hundreds of MB (one build shipped a 469 MB tmp_pack: stage 1,841 MiB vs a clean 1,393 MiB). Delete `tmp_pack_*` immediately before archiving — the objects they carry are already in the object store. A desktop app whose backend fails (broken venv) triggers its auto-repair (`hermes update` → `git fetch` in the checkout); on a blocked network the fetch hangs holding `FETCH_HEAD`/`tmp_pack` open and can lock the next build's stage removal (the removal guard surfaces it). Kill ALL stage processes (Electron, python, git children — not just `Hermes.exe`) before building.
- `7za x archive.zip -o<dir>` places the archive's TOP-LEVEL folder INSIDE `<dir>` — extracting a top-folder archive "to <root>" with `-o<root>` yields a nested `<root>\<TopFolder>\...` and leaves `<root>` itself empty (a 1.5 GB duplicate tree; install scripts then fail to find `scripts\*`). To install such an archive at `<root>`, extract to the PARENT (`-o(Split-Path <root> -Parent)`) and add a post-extraction sanity check that a known file exists at `<root>` (e.g. `scripts\Update-Portable.ps1`) — a silent wrong-target extraction exits 0.
- The official `hermes update` ends by STOPPING every running dashboard/serve process found by wmic command-line match (stale-backend cleanup: old Python vs new frontend → 401s). Its escape hatch `HERMES_DESKTOP_CHILD_PID` (comma-separated pids, read from the UPDATER's own env) only protects the desktop's own backend when the desktop app itself runs the update — an independent portable Update.exe carries no such env, so updating one install KILLS another install's backend (collateral, not stale). Fixed in `Update-Hermes.cs` (builder template + recompiled into every deployed Update.exe): before `hermes update`, scan `wmic process get ProcessId,CommandLine,ExecutablePath /FORMAT:LIST`, collect serve/dashboard pids whose ExecutablePath is NOT under the updated root, and set `HERMES_DESKTOP_CHILD_PID` to them. Verified: updating the C: copy while the D: app ran left D:'s backend untouched end-to-end (previously killed twice; the cleanup prints no "Stopping N" line when the exclusion works). C# must stay .NET Framework 4.0 csc-compatible (no `Contains(string, StringComparison)` — use `IndexOf(...) >= 0`). The Desktop-sync stage's root-wide pre-swap kill (`Update-Portable.ps1 -Stage SyncDesktop`) also excludes `Update.exe` by name — the updater sits under the portable root and was self-killing before its "Update completed" MessageBox; the ps1 child (orphaned) kept running so the update still completed, but no completion dialog ever showed. Completion flow (2026-08-01+): on success the updater auto-launches `Hermes.exe` via `Process.Start` — no dialog; if the auto-launch itself fails it falls back to a warning MessageBox ("Start Hermes.exe manually"); step failures still show the error MessageBox and return 1.
- An upstream updater may rebuild only source-tree Desktop artifacts; a Portable with an external `app/` needs an explicit validated sync/atomic-swap phase.
- A persisted Electron setting file does not prove the active BrowserWindow retained the value; verify through the app's IPC after the packaged window settles, then verify a user override survives restart.
- Directly launching the inner Electron executable may bypass launcher-provided Portable environment variables and accidentally read/write the system profile. Use the official Portable entry point or reproduce its environment exactly during smoke tests.
- Cleanup of deep venv/source trees can fail on Windows long paths; make cleanup non-fatal and use a temporary drive mapping plus `robocopy /MIR`/`rd` fallback.
- Git/ZIP source refresh does not equal update success when dependency installation or Desktop rebuild fails afterward.
- Removing Git-tracked source to reduce archive size makes the embedded checkout dirty; keep all tracked files and prune only ignored build/cache trees.
- A generated Portable source patch must be marker-bounded, idempotently removable before upstream update, and reapplied only after update; never auto-answer an upstream stash-restore prompt as the normal workflow.
- Packaging a checkout via robocopy preserves source mtimes, so the staged `.git`'s stat cache makes `git reset --hard` SKIP rewriting files: a CRLF working tree (copied from an `autocrlf=true` upstream) stays CRLF while the index expects LF (`core.autocrlf=false`). The build's own `git status` check passes via the stat cache, but on the END-USER machine ZIP extraction changes mtimes → git re-hashes → thousands of "M" entries → `hermes update` reports "Local changes detected" → stash → "Restore local changes now? [Y/n]" even on a perfectly clean install. Compounding: copying upstream's `.git` brings its build-dirtied index (patches were `git add`-ed during the build), so `checkout-index -f -a` (which writes FROM the index) still ships dirty files. Fix (in `Build-Hermes-Portable.ps1`, after replacing `$PackedGit` and setting `core.autocrlf=false`/`core.eol=lf`): `git rm -r --cached --quiet .` then `git reset --hard --quiet` — rebuilds index + working tree FROM HEAD, bypassing the stat cache and dropping the stale index — then THROW unless `git status --porcelain` is empty. Verified: extracted package is CLEAN (0 modified), update completes with no stash prompt and no [Y/n], auto-launches Hermes.
- The builder's own `upstream` checkout can get an EOL-only false positive from the patch stage (`Update-Portable.ps1 -Stage Patch`) — distinct from the packaged-checkout issue above. The script reads the three desktop Electron files (`main.ts`, `zoom.ts`, `zoom.test.ts`) and unconditionally converts CRLF→LF (`.Replace("\r\n","\n")`), then writes back LF via `WriteAllText` (UTF-8 no BOM) — so even the idempotent no-op path rewrites EOLs. With global `core.autocrlf=true` (hermes-home portable git config), `git status` flags the files "modified" with an EMPTY diff (content unchanged; EOL only). The script's own `Refresh-PortableGitIndex` does NOT cover the builder path: only called in the remove branch AND skipped via `-Skip:(-not $PortableRoot)` whenever the builder invokes with `-RepoPath`. Diagnosis: `git diff HEAD --numstat` empty + status modified ⇒ EOL artifact; confirm with `git config --show-origin core.autocrlf` (global file) and `git check-attr eol text -- <file>` (`unspecified` for `.ts` — official `.gitattributes` only pins `*.sh`/`Dockerfile` to LF). Cleanup: `git checkout -- apps/desktop/electron/main.ts apps/desktop/electron/zoom.ts apps/desktop/electron/zoom.test.ts`. FIXED (2026-08-03): option A — preserve each file's original EOL on write-back; the script now has `Read-NormalizedText` (detects CRLF vs LF per file) + `Write-TextWithOriginalEol` (defensive re-normalize, then restore original EOL), and all 8 `WriteAllText` sites restore the original EOL. Verified: apply keeps files CRLF (0 bare LF) with diff showing only patch content; remove leaves `git status` fully clean; a later full sync + apply/remove cycle stayed clean. If the false positive ever reappears, first check the two helpers are still intact. Full causal chain, option comparison, and verification recipe: the `Desktop patch line endings` appendix in `references/hermes-agent-windows-portable.md`.
- ZIP/TAR extraction on Windows can expose CRLF-only changes that the build tree's stale Git index hid. Before upstream update, if `git diff --cached --quiet` and `git diff --ignore-space-at-eol --quiet` both succeed, use `git add --renormalize .` followed by `git reset --mixed HEAD` to refresh normalization without preserving staged changes. If substantive differences exist, leave them visible for normal review/stash handling.
- A release archive must not contain the launched staging tree's Electron Local Storage or backend user state. In particular, exclude onboarding flags, `state.db*`, `.env`, auth pools, sessions, logs, memories, caches, snapshots, profiles, pairing state, and unrelated user-created customizations; keep `electron-user-data/` empty and seed only intentional non-secret defaults. Preserve the project-owned `hermes-portable-builder` skill in the embedded source checkout even though it is not an official bundled skill.
- Windows archive/update checkouts should use repository-local `core.longpaths=true`, `core.autocrlf=false`, and `core.eol=lf`; use `subst` for deep restore/removal operations.
- Do not run an in-place updater while Electron or backend processes from the portable root are alive.
- Packaging from a non-Git source tree can produce fallback/unpinned build metadata.
- Signing, PE resource editing, and icon stamping may be best-effort and require explicit artifact inspection.
- Root launcher/updater executables compiled without `/win32icon` do not inherit the inner Electron app's official icon; embed the authoritative `.ico` in every generated PE and verify it from the final archive.
- Repeated builds of one Hermes version can otherwise overwrite each other; append `yyyyMMdd-HHmmss` after `win-x64` in every Portable ZIP filename and verify that exact name after packaging.
- Antivirus/indexers can hold Windows build files; clean stale unpacked output and retry boundedly.
- PowerShell 5.1 with `$ErrorActionPreference='Stop'` treats ANY native-command stderr output as a terminating `NativeCommandError` — even when the command exited 0. Modern tools that write informational lines to stderr (npm 12+ `npm notice`, `uv` "Using CPython ..." / "Resolved N packages", git CRLF warnings, 7-Zip progress, `csc` notices) will abort a build script at the first such line with a misleading `FullyQualifiedErrorId : NativeCommandError` that looks like a real failure. Symptom signature: script dies at an innocuous `& npm.cmd run ...` / `& $Uv ...` line, the "error" text is a notice, and `$LASTEXITCODE` would have been 0. This is a systemic bug class — a build can get past npm (once wrapped) and then die at `uv venv`, `7za a`, or `git config` next. Fix: a `Invoke-NativeChecked` helper that (1) saves EAP, (2) sets `$ErrorActionPreference='Continue'`, (3) runs the scriptblock with `$output = & $Script` (do NOT use `2>&1` — that merges stderr ErrorRecords into the captured output and pollutes return values), (4) restores EAP in `finally`, (5) throws only when `$LASTEXITCODE -ne 0`, (6) returns `$output`. A `-AllowFailure` switch returns `$null` on nonzero exit instead of throwing — required for commands whose nonzero exit is meaningful (e.g. `git diff --quiet`, `git remote get-url` when no remote exists), callers then read `$LASTEXITCODE` themselves. Wrap every native invocation point (npm, uv, git, csc, 7za, and nested `powershell.exe -File` test harnesses) in the build script AND the deployed maintenance scripts (Update/Repair/Apply) in the same change — they ship byte-identical and hit the same failure mode. Note the `*>&1 | Tee-Object` log pipeline will still SHOW the NativeCommandError records (they land in the error stream and get merged); they are non-terminating noise once wrapped, so grep the log for the helper's throw message ("... failed with exit code N") or the final success line, not for the absence of `NativeCommandError`.
- `uv sync --no-install-project` never installs the project itself, so the venv's `python.exe -c "import hermes_cli"` fails with `ModuleNotFoundError` unless the embedded checkout is on `PYTHONPATH`. Runtime entry points (e.g. `hermes-cli.cmd`) set `PYTHONPATH=<bootstrap>;<agent_root>;...` precisely so source resolves; build/repair probes must replicate that explicitly. A probe that omits it may "pass" on a build machine whose ambient `PYTHONPATH`/`HERMES_PORTABLE_SITE_PACKAGES` leaks a different checkout's site-packages (false green), then fail in a sanitized `env -u PYTHONPATH` run (the true behavior). Set `$env:PYTHONPATH = @($checkout, $oldPythonPath) -join ';'` around the probe and restore it after — matching what the shipped launcher does, not what the build shell happens to export.
- Update.exe/console-launcher RUNTIME output encoding (verified 2026-08-10): the official upstream `package.json` postinstall echoes `'\u2705 Browser tools ready...'` (U+2705 checkmark). npm/node writes UTF-8 bytes, but a .NET 4.0 `Process` decodes redirected child stdout/stderr with `Console.OutputEncoding` — the OEM code page (GBK/936 on zh-CN) — so the UTF-8 checkmark renders as `?` in the live console stream (dialog MessageBox strings are UTF-16LE literals and stay intact; the corruption is ONLY in streamed child output). Fix pattern (in `Update-Hermes.cs` Main, before any child spawn): `Console.OutputEncoding = Encoding.UTF8` (affects both Process decode and console display), `Environment.SetEnvironmentVariable("PYTHONIOENCODING","utf-8")` + `PYTHONUTF8=1` (the bundled Python emits GBK when its stdout is a pipe otherwise), and restore the caller's original `Console.OutputEncoding` in a `finally`. Verify in the compiled exe: `MainBody` method name (UTF-8 metadata) and `PYTHONIOENCODING` literal (UTF-16LE #US heap) both present; `gbk` decode of `e29c85` reproduces the mojibake. When shipping to stage AND deployed copies without a full rebuild, compile both from the same template and diff: only PE timestamp (PE-header+8, 4 bytes) + MVID (16-byte GUID) may differ.
- Update.exe/console-launcher review findings (verified 2026-08-10, same session): (1) DOUBLE `WaitForExit()` is required in `RunCaptured` — the first call only guarantees the process handle exited; the async `BeginOutputReadLine`/`BeginErrorReadLine` event handlers may still be draining their buffers on the thread pool, so a failure `MessageBox` can pop while child output keeps scrolling on the console (looks like "commands still running after the dialog"). A second parameterless `WaitForExit()` waits for those handlers to finish; verify via reflection on `RunCaptured`'s IL (count `Process.WaitForExit` callvirt tokens resolved by name — a MemberRef is stored once, so count CALL SITES, not metadata string occurrences). (2) `IsForeignServe` path-boundary bug: `root` is `TrimEnd`'d (no trailing separator), so a bare `exe.StartsWith(root, OrdinalIgnoreCase)` also matches a DIFFERENT install whose path merely begins with this root (`...-Portable-Beta\` or `...Portable 2\`), misclassifying its serve/dashboard process as "inside this root" and leaving it unprotected from the official updater's kill sweep. Compare against `root + Path.DirectorySeparatorChar` (or `Equals(root)`) instead. Dialog/step flow itself is safe: every failure branch is a synchronous `return` after `WaitForExit` + `MessageBox` (modal), so no child command can continue after a dialog. (3) EMOJI TOFU AFTER THE UTF-8 FIX: once decoding is correct, the official postinstall `\u2705` checkmark renders as a `□` box — conhost fonts (raster/Consolas/NSimSun) have no emoji glyphs. A display-only mapper (`SanitizeForConsole`: `\u2705`/`\u2714`/`\u2713` → `√` U+221A, applied in the OutputDataReceived/ErrorDataReceived handlers before `Console.WriteLine`, keeping the captured log in original Unicode) was added and then REVERTED 2026-08-10 at the user's request (they preferred the tofu box over the substituted glyph; `√` looked too large, and `✓`/`✔` are NOT in GBK so console fonts lack their glyphs too). Current shipped behavior: no sanitizer — child output is written to the console as decoded, emoji render as `□`. If a glyph substitution is ever wanted again, verify GBK encodability of the target first (ASCII `v`/`[OK]`/`>`/`√` are the only safe candidates; `✓` U+2713 and `✔` U+2714 are not GBK-encodable).
- Official `upstream/scripts/desktop-update.ps1` (429 lines, landed 2026-08-10) is the repo-owned update hand-off the Desktop Update button spawns via a `cmd start` wrapper. It solves the FROZEN-BINARY problem (staged Tauri exe has no self-update path, so updater fixes only ship with new installers; a repo-owned script refreshes every `hermes update`). Its transferable ideas, all adopted into `Update-Hermes.cs` on 2026-08-10: (a) FAIL CLOSED preflight gates — wait for the Desktop process to exit (30s) and for the venv shim to unlock (20s), aborting with nothing changed otherwise; the 2026-08-09 Access-denied brick came from updating under a live backend. Our Portable equivalent: `WaitForRootProcessesExit(root, 30)` scans `Process.GetProcesses()` for Hermes.exe/python.exe under the root (directory-boundary match) and aborts via the gate before touching the venv. (b) ONE retry of `hermes update` when exit != 0 && != 2 (2 = "close all Hermes windows", not retryable) — the update-boundary class (fresh code on disk, stale code in memory). (c) Result-file hand-off: every exit path writes `data\hermes-home\.hermes-update-result.json` `{ok, exit_code, message, finished_at}` via a unified `Finish()` (also removes the re-entrancy marker); `Hermes-Desktop.cs` `ShowUpdateResultIfFailed` reads+deletes it on next launch and pops a dialog when ok=false, so a detached/crashed update is never silent. (d) Re-entrancy marker `data\hermes-home\.hermes-update-in-progress` containing OUR pid, reclaimed when stale (pid dead), removed only while owned — prevents two concurrent Update.exe from racing over the same checkout/venv. Also official does UTF-8 console + PYTHONIOENCODING/PYTHONUTF8 (same as our fix), WMI-detached relaunch to avoid Electron AttachConsole console-inheritance, `AllowSetForegroundWindow` focus hand-off, and treats "Desktop build failed" inside an exit-0 `hermes update` as fatal (our Portable flow already avoids this: the SyncDesktop stage rebuilds Desktop itself and checks Hermes.exe size). Note the official script lands in the packaged checkout automatically (it is part of upstream), so it ships in every Portable — it is inert there (the Desktop Update button is not wired to Portable's Update.exe flow).
- The `__pycache__` cleanup of the staged hermes-agent source tree MUST run AFTER the web UI build stamp step: the stamp step imports `hermes_cli` through the staged venv (PYTHONPATH points at the checkout) and re-creates `__pycache__` under the source tree, so a cleanup placed before it lets fresh .pyc files slip into the archive (observed 2026-08-05: ZIP shipped `hermes-agent/.../__pycache__/*.pyc` stamped seconds before archive creation; fixed by moving the `Get-ChildItem $Checkout -Directory -Filter '__pycache__' ... | Remove-Item` block after the stamp `try/finally`). Archive inventory check: `7za l` — the only remaining `__pycache__` entries must be under `runtime\\python\\...\\Lib\\` (CPython's own precompiled stdlib bytecode, normal); any entry under `data\\hermes-home\\hermes-agent\\` means the cleanup ran too early.
- The Desktop stage of `Build-Hermes-Portable.ps1` historically ran bare `npm run typecheck/build` with NO dependency install of its own (only TUI and web have `npm install --workspace` steps), relying on the build machine's leftover `node_modules`. Whenever upstream adds a Desktop dependency, the stale tree breaks the build with TS2307 (verified 2026-08-09: `get-windows@9.3.0` from the `read_window_below` tool failed typecheck until `npm.cmd install --workspace apps/desktop --include=dev --silent --no-fund --no-audit --progress=false` was added right after the Portable source patch apply, before typecheck; npm hoists workspace deps to the ROOT `node_modules` — check `upstream/node_modules/<pkg>/`, not `apps/desktop/node_modules/`). The later `git checkout -- package-lock.json` (after the TUI/web steps) still restores the lockfile, so the install step cannot dirty the checkout. HOISTING IS NOT GUARANTEED: as of 2026-08-10 the official root `package.json` no longer declares `electron` at all (it lives only in `apps/desktop` devDependencies, pinned 40.10.2), so `npm install --workspace apps/desktop` leaves it at `apps/desktop/node_modules/electron` and the root `node_modules/electron` does NOT exist — `Build-Hermes-Portable.ps1` failed at the `$electronVersion` read (`Get-Content ... node_modules\electron\package.json` → PathNotFound, and the bash wrapper masked the real exit code behind `tail`). Fixed with a fallback lookup: root `node_modules\electron\package.json`, else `apps\desktop\node_modules\electron\package.json`, throw if neither. If upstream moves a dependency again, check the root `package.json` declaration before assuming where npm put a package.
- Offline-first npm/Electron caches (2026-08-09): `Build-Hermes-Portable.ps1` sets `npm_config_cache`, `ELECTRON_CACHE`, `ELECTRON_BUILDER_CACHE` to `builder\assets\npm-cache` / `electron-cache` / `electron-builder-cache` and every workspace install uses `--prefer-offline` — the cache dirs ARE the assets dirs, so the first online build seeds them and later builds are fully offline (verified: no electron download lines in the log; uv/Python/Node/Git all "Using cached from assets"). Electron download honors `ELECTRON_CACHE`/`ELECTRON_BUILDER_CACHE`. Do NOT prune npm/electron caches — content-addressed, old entries stay valid.
- PowerShell 5.1 中,原生可执行文件直接接 `| Select-Object -First 1` 存在竞态:Select-Object 取到第一行后立即关闭管道,若原生进程(uv、git 等)此时尚未写完 stdout 会收到 broken pipe 并以 -1 退出 —— `Invoke-NativeChecked` 捕获到 `$LASTEXITCODE = -1` 且 stderr 无任何输出,表现为"install 成功但紧随其后的 find 间歇性失败"(实测 2/3 失败,uv 0.12.0 python find --managed-python)。修复:用子表达式先完整收集输出再截取 —— `(& $Uv python find ...) | Select-Object -First 1`(实测 5/5 成功)。`| Out-Host`、`| Out-Null`、`| Out-String` 会消费全部输出,无此竞态。排查脚本:Build-Hermes-Portable.ps1 170 行(Install-ManagedPython find)、278 行(--system 候选)、521 行(staged origin get-url),Repair-Portable.ps1 的 uv python find 调用,Verify-Portable.ps1 97 行(Bash --version)。症状:构建在 "Downloading cpython-..." 后紧跟 "Managed Python 3.11 find failed with exit code -1" 失败,但同一命令手动执行却成功(间歇性)。注意:Build-Hermes-Portable.ps1 已移除 -SkipDesktopBuild 开关(2026-08-07,避免两条构建路径行为不一致干扰排查),Desktop 构建始终执行;任何跳过一次完整构建的临时开关都会让 Python 解析走不同路径,掩盖此类管道竞态。
- When invoking the bundled `7za.exe` manually from git-bash, pass the archive path RELATIVE to the current directory (or a native `D:\\...` path) — an absolute MSYS path like `/d/Hermes-Agent-Portable-Builder/dist/x.zip` is NOT reliably converted for 7za and the archive gets written somewhere else (observed 2026-08-05: `a` reported "Everything is Ok" with a real Archive size, but the file was nowhere on disk and `l`/`t` then failed with "cannot find the specified file"; an empty `D:\\d\\` directory was left behind). The same applies to the `-o<dir>` EXTRACTION/OUTPUT target: `-o/tmp/foo` was resolved as `D:\\tmp\\foo` while the later `rm -rf /tmp/foo` deleted the git-bash `/tmp` copy — leaving `D:\\tmp\\` behind (observed 2026-08-08: `D:\\tmp\\skillcheck\\` survived). Always use native `D:\\...` or cwd-relative paths for BOTH arguments, and when cleaning up verify the path that was actually written. The build script itself is unaffected (PowerShell invokes it with native paths).

- When running PowerShell one-liners FROM git-bash, a double-quoted `-Command "...$var..."` gets EVERY `$var` (`$errs`, `$tokens`, `$null`, `$_`, ...) expanded/emptied by bash before PowerShell parses it — observed 2026-08-11: a `[Parser]::ParseFile` syntax check via `-Command "$tokens=$null; $errs=$null; ..."` failed with `EmptyPipeElement` because bash swallowed the variables (the .ps1 itself was fine). Robust fix: write the one-liner to a temp `.ps1` and run `powershell.exe -File <temp>` (delete after), or single-quote the whole `-Command` argument, or avoid `$` variables entirely. See the `bash ↔ PowerShell interop` section in `references/hermes-agent-windows-portable.md`.
- Inventory-grepping `7za l` output from git-bash: do NOT write backslash path regexes (`'runtime\\\\bin\\\\hermes-cli.cmd'`) — the Hermes-terminal JSON + bash layers collapse `\\\\` into `\\`, and grep then reads `\\b`/`\\h` as escapes, silently missing entries (observed 2026-08-11: only `hermes-tui.cmd` matched, `hermes-cli`/`hermes-dashboard` missed, and a re-run returned 0). Use `grep -F` fixed strings, match only the basename token (`grep -iE 'hermes-(cli|tui|dashboard)\\.cmd'`), or let `.` match the separator. Full details in `references/hermes-agent-windows-portable.md` Pitfall 5.
- PATCH-TOOL DOUBLE-BACKSLASH TRAP in PowerShell source (observed 2026-08-12): when editing `Build-Hermes-Portable.ps1` (or any .ps1 with Windows paths) via the patch tool, the `diff` display and even a plain text read can LOOK correct while the file actually contains doubled backslashes. Root cause: read_file/grep output renders one backslash as `\\` (JSON escaping), so copying that text into a patch `new_string` writes the literal two characters `\\` into the file — `Join-Path $Root 'scripts\\\\Verify-Portable.ps1'` becomes a path with TWO backslashes per separator (`scripts\\\\Verify-Portable.ps1`), which silently breaks Test-Path/Join-Path on Windows. The patch tool's fuzzy matching tolerates the old_string mismatch, so the edit "succeeds" with corrupted output. SYMPTOM: a removed line leaves `\\\\` behind in the diff; or a `git diff`/read shows more backslashes than the original. FIX: after ANY patch touching a Windows path in a PowerShell file, verify bytes with `sed -n 'N,Mp' file | od -c` (a single `\\` per separator is correct) — do NOT trust the diff display; repair doubled separators with a Python read/replace/write (`content.replace(r"'scripts\\\\Verify-Portable.ps1'", r"'scripts\\Verify-Portable.ps1'")`) and re-verify with od. Also re-run the PowerShell parser syntax check (`[System.Management.Automation.Language.Parser]::ParseInput`) after the repair since a dangling escape can break parsing.

- Offline-boot verification on the build machine: a proxy-blackhole simulation (`HTTP(S)_PROXY=http://127.0.0.1:9` + `NO_PROXY=127.0.0.1,localhost` on the spawned backend) is INSUFFICIENT - git fetch/`ls-remote` ignore proxy env vars and still reach the real network, and DNS still resolves, so it cannot reproduce a true no-network hang. The faithful simulation is per-exe Windows Firewall OUTBOUND block rules (`netsh advfirewall firewall add rule name=X dir=out program="<abs exe>" action=block`) applied to the launcher, the inner Electron exe (`app\Hermes.exe`), and the bundled `runtime\python\...\python.exe`, then launch via `powershell -Command "Start-Process -FilePath ... -WorkingDirectory ..."` (from git-bash, `cmd //c start` opened a cmd window but the exe never produced processes/logs - observed 2026-08-11). Verified 2026-08-11 on a fresh stage tree with all three exes firewalled: the app booted fully offline - `HERMES_BACKEND_READY`, renderer WS accepted (`ws accepted peer=127.0.0.1`), first-run `config.yaml` seeded, ~11s - proving the boot chain (desktop resolve -> spawn `serve --host 127.0.0.1 --port 0` -> ready line -> localhost HTTP/WS probes -> renderer local bundle) has no network dependency. The desktop's update poller (renderer -> backend `/api/hermes/update/check` -> `check_for_updates()` -> `git fetch origin/main`) is client-side fire-and-forget and does NOT block the boot screen, but the git fetch has NO timeout in either `runGit` (main.ts) or `check_for_updates` (banner.py), so a genuinely offline launch leaves a hanging git fetch holding the packaged checkout's FETCH_HEAD/pack locks. Test cleanup contract: delete the firewall rules, kill stage processes by path, then sanitize the stage tree immediately - `config.yaml` MUST be removed (the build gate fails on any leftover), plus `state.db*`, `projects.db`, `auth.*`, `.env`, `.update_check`, `*_models_cache.json`, `logs/`, `sessions/`, `memories/`, caches, and `electron-user-data` payloads; keep only `git/ hermes-agent/ node/ skills/ SOUL.md web-ui-build-stamp.json`.
- Network-resilient upstream sync (observed 2026-08-12, IPs stale by the same day): if `git fetch` fails with "Failed to connect to github.com:443 ... Could not connect to server" while `api.github.com` / `codeload.github.com` / `raw.githubusercontent.com` still respond, the local DNS (hotspot/router) is resolving `github.com` to an unroutable APAC edge (e.g. 20.205.243.166 — IPv4 connect timeout, no IPv6 AAAA). Diagnose candidate edges with `curl --resolve github.com:443:<ip> --connect-timeout 8 https://github.com` (expect 200) and pin a working edge to `C:\Windows\System32\drivers\etc\hosts`. NOTE: specific edge IPs are NOT stable across sessions — 140.82.112.3 / 140.82.114.3 worked in the morning of 2026-08-12 but timed out later the same day, and 20.205.243.166 (initially "bad") became the working pin. Always re-probe edges at build time; never trust a recorded IP. WINDOWS HOSTS QUIRK: only the FIRST matching entry per hostname is used — no automatic failover; swap the lines to switch edges. Verify the fetched HEAD equals the API-reported main SHA (`curl -sS https://api.github.com/repos/NousResearch/hermes-agent/commits/main` and compare `"sha"`).

## Verification

Before reporting success, provide real output for:

1. target build command and exit status
2. packaged file inventory proving the runtime/backend exists
3. backend import or `--help` probe using the bundled runtime
4. application startup/readiness
5. filesystem audit showing writes remain under the portable root
6. move-and-relaunch test
7. updater dry check plus a real update/repair test from a moved root, with all app processes stopped
8. proof that immediately before upstream update the embedded checkout has empty `git status --porcelain` and empty `git stash list`, and that the generated Portable patch can apply/remove/apply without duplication
9. proof that the updater reached its terminal success state, cleared interruption markers, and left imports/backend readiness healthy
10. archive integrity and inventory checks after compression; extract and rerun only when archive/extraction behavior changed, corruption is suspected, or the user explicitly requests it
11. release-state audit proving Electron `userData` has no payload and backend home contains no state database, credentials, sessions, logs, memories, or caches beyond intentional distribution defaults
12. first-run/onboarding verification from a clean staging data root before compression, using screenshot/AX evidence or Electron CDP text assertions; use disposable extraction only when extraction behavior is the feature under test
13. when a checksum artifact is part of the requested release, regenerate it after the final sanitized rebuild and compare a read-back hash against the manifest; when the user explicitly requests no checksum file, verify archive integrity directly without creating or reporting an omitted checksum artifact

After any source edit made after packaging, rebuild the affected artifact, replace it in staging, rerun staging gates, and regenerate the archive. Do not repeat a full extraction smoke test unless the archive/extraction layer is itself under test.

On cross-platform suites, separate product regressions from host-incompatible fixtures. If a full Windows run fails only tests that fabricate POSIX absolute paths, record the aggregate result, then run the directly relevant Windows/portable test files plus typecheck, lint, and runtime smoke tests. Do not describe the full suite as passing.

For research-only requests, clearly separate proven upstream behavior from proposed modifications and name the exact source files supporting each conclusion.

## Web Dashboard: two frontends, one server

Use when `hermes dashboard` serves the wrong frontend, a browser or the
desktop preview pane shows **"Desktop IPC bridge is unavailable."**, or the
web UI is missing/stale (`hermes_cli/web_dist`). Two different bundles share
the same FastAPI dashboard server:

| Bundle | Location | Browser behavior |
|---|---|---|
| Desktop bundle | `app.asar.unpacked/dist` (has `electron-main.mjs`, `electron-preload.js`) | Requires `window.hermesDesktop` (Electron preload IPC bridge). Plain browser/preview pane has no bridge → boot hook fires the toast and disables chat. |
| Web bundle | built from `web/` (vite, `outDir: ../hermes_cli/web_dist`) | Browser-native. Chat drives the agent over `/api/ws` + `/api/pty`. Server injects `__HERMES_SESSION_TOKEN__` / `__HERMES_BASE_PATH__` / `__HERMES_AUTH_REQUIRED__`. |

Resolution rule (`hermes_cli/web_server.py`): `WEB_DIST = $HERMES_WEB_DIST`
if set, else `<hermes_cli>/web_dist`. **The env var wins.**

Root cause of the leak: the desktop app spawns its backend with
`HERMES_WEB_DIST=<app.asar.unpacked/dist>` + `HERMES_DESKTOP=1`, and every
agent/user terminal spawned from the app inherits it — a standalone
`hermes dashboard` from such a shell serves the DESKTOP bundle. The
desktop-embedded flow is correct and must keep the desktop bundle (it spawns
`python -m hermes_cli.main` directly, never through `hermes-cli.cmd`).

### Diagnose

```bash
curl -s http://127.0.0.1:9119/ | grep -oE '__HERMES_SESSION_TOKEN__|hermesDesktop|index-[A-Za-z0-9_]+\.js' | sort -u
```

- Web bundle: token present, bundle hash matches the web build (e.g. `index-Cv1Lntuh.js`).
- Desktop bundle: no token, served JS references `window.hermesDesktop`.

### Fix

1. Build the web frontend (network needed for first install):
   ```bash
   cd <repo> && npm install --workspace web --include=dev --silent --no-fund --no-audit --progress=false && cd web && npm run build
   ```
   Output lands in `hermes_cli/web_dist` (vite outDir), the server's default fallback.
2. Launch with the override so a leaked inherited value can't win:
   ```bash
   export HERMES_WEB_DIST="<repo>/hermes_cli/web_dist"
   hermes-cli.cmd dashboard --no-open
   ```
   Unsetting the var achieves the same.
3. Re-run the curl check: token + NEW bundle hash. Startup log should show
   `HERMES_DASHBOARD_READY port=9119`.

Durable fix in this project: `hermes-cli.cmd` clears `HERMES_WEB_DIST`; the
build/update/verify scripts prebuild + assert `hermes_cli/web_dist` (fatal in
build, non-fatal with stale-bundle deletion in update, mirroring the TUI
contract); staged `git clean -fdx` excludes `hermes_cli/web_dist/`.

### Pitfalls

- `hermes_cli/web_dist/` is gitignored upstream — `git clean -fdx` wipes it
  unless excluded with `-e` (mirror `-e hermes_cli/tui_dist/`).
- `web` is a root npm workspace; its lockfile is the ROOT `package-lock.json`.
  `npm install --workspace web` can rewrite it → restore with
  `git checkout -- package-lock.json` (same guard as the TUI step).
- The desktop preview pane is a plain webview WITHOUT the bridge —
  desktop-bundle pages are expected to fail there; that's a symptom, not a bug.
- No runtime frontend build: without `web_dist` the server returns the JSON
  "Frontend not built" error. The lazy install only covers fastapi/uvicorn extras.
- The dashboard backend also ticks cron and gateway pub/sub — a real backend,
  not a static file server; don't kill it casually.
- After fixing, restart the dashboard process (it caches `WEB_DIST` at import time).

## References

- `references/hermes-agent-windows-portable.md` — SINGLE consolidated reference file (merged 2026-08-10 from the former 12-file layout; every appendix keeps its original content). Main body: Hermes Agent Desktop `main` packaging and Windows portable conversion notes from a source audit (verified relative-wrapper pattern, archive validation sequence). Appendices (read by their `# Appendix:` heading): `Desktop patch line endings`, `Electron first-run defaults`, `Portable builder web-dist fix`, `Portable install diagnosis`, `uv-managed Python portable updates`, `Windows managed-python dedup`, `Windows csc compilation`, `Windows console output encoding`, `Windows PowerShell build execution`, `Windows PowerShell native commands`, `Update.exe error dialog`.
- MERGED 2026-08-10: the two pre-archive release gates became in-script functions `Test-PortablePythonContract` / `Test-PortableNoEditableInstall` inside `Build-Hermes-Portable.ps1` (they were standalone template scripts, only ever invoked by the build script, never shipped in the release; folding them in removes two files with zero behavioral change). Calls: `Invoke-NativeChecked 'Portable Python contract test' { Test-PortablePythonContract $Stage | Out-Host }` (plus the NoEditableInstall twin). VERIFY after such a merge: PowerShell AST extraction of a function body (`FunctionDefinitionAst.Body.Extent.Text`) ALREADY includes the outer `{ }`, so rebuilding a function as `"function Name([string]$Root) { <body> }"` nests a scriptblock literal and the function silently returns its own source text as a string (looks like "executed but empty output", and negative tests never throw). Correct reconstruction is `"function Name([string]$Root) <body>"` with NO extra braces. Positive gate on the clean stage must return the full JSON (PythonContract: 17 fields incl. BundledPythonVersion matching the official selector); negative gate on the deployed dir must throw (`Release contains user-owned config.yaml`). README.md (MCP 回归门禁 section) and `references/hermes-agent-windows-portable.md` (input list + invocation) were updated in the same change.