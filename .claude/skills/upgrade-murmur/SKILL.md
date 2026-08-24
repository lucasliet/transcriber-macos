---
name: upgrade-murmur
description: Pull upstream murmur-youtube changes into this fork. Previews, backs up, merges with conflict-aware resolution, validates, and surfaces breaking changes.
---

# About

This repo forked `per-simmons/murmur-youtube` and diverged hard: the Windows/Avalonia side
was deleted outright, the interface was translated to pt-BR, a third speech engine
(ElevenLabs, no API key) was added, and several features from an even older app
(`transcriber-macos`) were ported in — self-update, custom hotkey combinations, a hybrid
recording mode, the notch overlay, a plain-text log. Pulling upstream naively would either
blow those away or silently reintroduce Windows and English strings.

Run `/upgrade-murmur` inside the repo from `claude`. This is the supported upgrade path: the
agent previews the diff, creates rollback points, performs the merge, resolves conflicts
with this fork's permanent decisions in mind, and validates the build.

## How it works

**Preflight:** refuses to touch anything with a dirty working tree. If the `upstream` remote
is missing, adds it (default: `https://github.com/per-simmons/murmur-youtube.git` — the
skill will ask).

**Backup:** creates a timestamped rollback branch + tag before doing anything. Printed at the
end so you can `git reset --hard` back.

**Preview:** buckets upstream changes into categories so you know what's about to land:
- **Core dictation** (`Sources/MurmurYouTube/Core/`) — `DictationController.swift` and
  `HotkeyMonitor.swift` were substantially rewritten here (hybrid mode, custom combinations,
  the `.success` state, `isBusy`/`isCapturing`). Highest conflict risk in the repo.
- **Transcription engines** (`Sources/MurmurYouTube/Transcription/`) — `AppleSpeechEngine.swift`
  has the pt-BR locale pin; `TranscriptionEngine.swift` is the protocol `ElevenLabsEngine.swift`
  and `HCaptchaSolver.swift` implement against. A protocol change here is the one upstream
  change that can silently break the ElevenLabs engine without a merge conflict, because
  those two files don't exist upstream and so never show up as conflicted.
- **UI** (`Sources/MurmurYouTube/UI/`) — `MurmurYouTubeApp.swift` and `SettingsWindow.swift`
  carry both the pt-BR translation and the ElevenLabs/hotkey/overlay settings; high conflict
  risk. `NotchPanel.swift`, `NotchIndicatorView.swift`, `NotchShape.swift`, and
  `HotkeyRecorder.swift` don't exist upstream.
- **Support** (`Sources/MurmurYouTube/Support/`) — `Settings.swift` grew `customHotkey`,
  `recordingMode`, `hudStyle`, `hotkeyBinding`; `FileLog.swift` and `UpdateManager.swift`
  don't exist upstream.
- **Dictionary** (`Sources/MurmurDictionary/`, `Tests/MurmurDictionaryTests/`) — low risk,
  tracks upstream directly. `shared/dictionary-test-vectors.json` was deleted along with the
  Windows side; the vectors now live solely in `Tests/MurmurDictionaryTests/`.
- **Windows** (`windows/`, `.github/workflows/windows.yml`, `shared/`) — deleted. See
  Permanent decisions below; never let a merge bring any of it back.
- **CI** (`.github/workflows/`) — `release.yml` and `claude-code-review.yml` have no upstream
  equivalent at all; `macos.yml` does and may receive real upstream fixes worth taking.
- **Docs** (`README.md`, `AGENTS.md`, `docs/`) — heavily rewritten; conflicts here are
  narrative, not mechanical, and need an actual read, not just marker resolution.
- **Resources / packaging** (`Resources/`, `Package.swift`, `Makefile`) — bundle id,
  entitlements, Info.plist, the FluidAudio version pin, the `--show-bin-path` build step.

**Choice:** you pick merge (one-pass), cherry-pick (specific commits), rebase (linear
history), or abort.

**Conflict preview:** dry-run merge to show which files would conflict before you commit.

**Validation:** `swift build` after the merge (this fork has no `npm`/`package.json` — it's
SwiftPM). If no Swift toolchain is available in the current environment (true for a
Linux/container session), say so explicitly and hand the validation step to the user instead
of skipping it silently.

**Breaking changes:** this repo has no `CHANGELOG.md`, so there's no `[BREAKING]` marker to
parse. Instead, the skill diffs `Sources/MurmurYouTube/Transcription/TranscriptionEngine.swift`
specifically — a signature change there is the one kind of upstream change that breaks
`ElevenLabsEngine.swift` without ever showing up as a conflict — and scans upstream commit
subjects for signals worth a manual look (macOS platform bump, dependency version bumps,
`Settings` key changes).

**Summary:** prints rollback tag, new/upstream HEADs, and flags anything from the sweeps in
Step 6 that still needs a human decision.

---

# Operating principles

- Never proceed with a dirty working tree.
- Always create a rollback point (backup branch + tag) before touching anything.
- Prefer git-native operations. Do not rewrite files manually except to resolve conflict
  markers, restore a permanent decision below, or re-translate a string to pt-BR.
- Default to MERGE (one-pass conflict resolution). Offer REBASE only if the user explicitly
  asks.
- Keep token usage low: use `git status`, `git log`, `git diff`, and only open files that
  actually have conflicts or that Step 6's targeted sweeps flag.

---

# Permanent decisions (override upstream, always)

These are settled. A clean, conflict-free merge can still reintroduce any of them by pulling
in a new upstream file or a new call site — the sweeps in Step 6 exist because "no conflict"
does not mean "nothing to check."

**1. No Windows app, ever.** `windows/`, `.github/workflows/windows.yml`, and
`shared/dictionary-test-vectors.json` were deleted in this fork because the Windows side
never ran on real hardware and cost a CI runner on every PR for code nobody maintained. If
upstream re-adds or modifies anything under `windows/`, or touches `shared/`, do not bring it
back — drop that hunk. The dictionary vectors upstream still syncs to a C# side live solely
in `Tests/MurmurDictionaryTests/dictionary-test-vectors.json` here; take *content* changes to
the vectors (new test cases, corrected expected output) but never the shared-file sync
mechanism itself. Upstream's `windows/README.md` and `docs/PARAKEET-WINDOWS.md` references in
`README.md`/`AGENTS.md` should also not resurface.

**2. The interface is Brazilian Portuguese, not English.** Every user-facing string — menu
items, Settings labels, HUD/notch text, dashboard, alert dialogs, error messages — was
translated. When a merge brings in a new or changed upstream string (a new menu item, a new
Settings toggle, a new error case), translate it to pt-BR as part of resolving that hunk;
don't take the upstream English string verbatim just because it merges cleanly. This applies
especially to `MurmurYouTubeApp.swift`, `SettingsWindow.swift`, `MainWindow.swift`,
`ComparisonWindow.swift`, `DictionaryPanel.swift`, and `DashboardHTML.swift`.

**3. `AppleSpeechEngine`'s locale is pinned to pt-BR, not `Locale.current`.**
`Locale.current` follows the system language and silently transcribes Portuguese speech as
English on a Mac set to English — no error, just wrong output. If upstream's `init` for this
engine changes, keep (or restore) the `Locale(identifier: "pt-BR")` default.

**4. ElevenLabs is a permanent third engine**, alongside Apple and Parakeet — with no API key,
no account, streaming → batch → local fallback. It's implemented entirely in two files
upstream doesn't have: `Sources/MurmurYouTube/Transcription/ElevenLabsEngine.swift` and
`HCaptchaSolver.swift` (full protocol documented in `docs/ELEVENLABS.md`). Because those files
never conflict, an upstream change to the shape of the engine layer can silently strand them.
Whenever upstream touches any of these, re-check and re-wire the ElevenLabs engine to match:
- `Transcription/TranscriptionEngine.swift` — the protocol both files implement.
- `Support/Settings.swift` — the `SpeechEngineChoice` enum and `engine` property.
- `Core/DictationController.swift` — the `engineForCurrentSetting()` switch.
- `Core/EngineComparison.swift` — the list of engines compare mode runs.
- `UI/SettingsWindow.swift`, `UI/MurmurYouTubeApp.swift`'s `MenuContent` — the engine pickers.
"Port, don't drop": if upstream adds a capability to the engine protocol (e.g. a new
lifecycle hook), ElevenLabsEngine needs an implementation of it, not just Apple/Parakeet.

**5. Features restored from the old `transcriber-macos` app are permanent, not upstream's to
remove.** If a merge touches the files below and takes "upstream's version" wholesale instead
of a real merge, one of these silently disappears:
- **Self-update** — `Support/UpdateManager.swift`, wired into `MurmurYouTubeApp.swift`'s
  `applicationDidFinishLaunching` and the "Verificar atualizações…" menu item. Compares the
  latest GitHub release tag against `Resources/Info.plist`'s `CFBundleShortVersionString`.
- **Custom hotkey combinations** — `Core/KeyCombination.swift`, `UI/HotkeyRecorder.swift`,
  and `Settings.customHotkey` / `Settings.hotkeyBinding`, alongside the three bare-modifier
  `PushToTalkKey` options upstream has.
- **Hybrid recording mode** — the tap-to-latch behavior in `Core/HotkeyMonitor.swift`
  (`RecordingMode.hybrid`, the default) layered on top of upstream's plain push-to-talk.
- **The notch overlay** — `UI/NotchPanel.swift`, `NotchIndicatorView.swift`, `NotchShape.swift`,
  falling back to upstream's `HUDPanel`/`HUDView` on a screen without a physical notch
  (`Settings.hudStyle`, chosen in `AppDelegate.presentOverlay()`).
- **`FileLog`** — `Support/FileLog.swift`, a plain-text mirror of the events that matter at
  `/tmp/murmur-youtube.log`, alongside upstream's `os.Logger`-only `Log.swift`.
- **CI is intentionally different from upstream.** `release.yml` (Claude Code CLI release
  notes, ad-hoc-signed `.zip` published via `ncipollo/release-action`) and
  `claude-code-review.yml` (two-provider Anthropic/z.ai review with a published-comment
  check) have no upstream equivalent — never let a merge overwrite or delete them. `macos.yml`
  does exist upstream and may carry real fixes (Xcode selection, test filters); take those,
  but keep this fork's version without the `shared/` diff step upstream's copy still has.

---

# Step 0: Preflight

Run:
- `git status --porcelain`

If output is non-empty:
- Tell the user to commit or stash first. Stop.

Confirm remotes with `git remote -v`. If `upstream` is missing:
- Ask the user for the upstream repo URL (default: `https://github.com/per-simmons/murmur-youtube.git`).
- `git remote add upstream <url>`
- `git fetch upstream --prune`

Detect the upstream branch:
- `git branch -r | grep upstream/`
- Prefer `upstream/main`. Fall back to `upstream/master`. If neither, ask.
- Store as `UPSTREAM_BRANCH`. All commands below that reference `upstream/main` use
  `upstream/$UPSTREAM_BRANCH` instead.

Fetch fresh:
- `git fetch upstream --prune`

# Step 1: Safety net

```
HASH=$(git rev-parse --short HEAD)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
git branch backup/pre-upgrade-$HASH-$TIMESTAMP
git tag pre-upgrade-$HASH-$TIMESTAMP
```

Save the tag name. You'll print it in Step 7 for rollback.

# Step 2: Preview

Compute base:
- `BASE=$(git merge-base HEAD upstream/$UPSTREAM_BRANCH)`

Show what's coming:
- `git log --oneline $BASE..upstream/$UPSTREAM_BRANCH`

Show local drift:
- `git log --oneline $BASE..HEAD`

File-level impact:
- `git diff --name-only $BASE..upstream/$UPSTREAM_BRANCH`

Bucket files into the categories listed in **How it works** (Core dictation, Transcription
engines, UI, Support, Dictionary, Windows, CI, Docs, Resources/packaging). Call out high-risk
buckets specifically, and flag immediately if the upstream diff touches `windows/`, `shared/`,
or `.github/workflows/windows.yml` — that's Permanent decision #1, surface it before the user
even picks a merge strategy.

**Large-drift check:** if upstream has many commits and the user has heavy local drift,
mention that reapplying customizations onto a fresh upstream checkout might be cleaner than
merging. Don't push — offer.

Ask the user with the active agent's user-question mechanism:
- A) **Full update** — merge all upstream changes (default)
- B) **Selective** — cherry-pick specific commits
- C) **Abort** — preview only
- D) **Rebase** — linear history, resolves conflicts per commit

If Abort: print rollback info and stop.

# Step 3: Conflict preview (no commits yet)

If Full update or Rebase, dry-run:
```
git merge --no-commit --no-ff upstream/$UPSTREAM_BRANCH; git diff --name-only --diff-filter=U; git merge --abort
```

Show the conflict list. If empty, say "clean" and proceed — but still run Step 6's sweeps,
since a clean merge is exactly how the permanent decisions get reintroduced silently. If
non-empty, let the user bail.

# Step 4A: Full update (MERGE — default)

- `git merge upstream/$UPSTREAM_BRANCH --no-edit`

If conflicts:
- `git status` → list conflicted files.
- For each file:
  - Open it.
  - Resolve only conflict markers.
  - Preserve intentional local customizations — check the Permanent decisions section above
    before accepting "upstream's side" for any hunk in a file it names.
  - Incorporate upstream improvements.
  - Translate any new upstream-side English string to pt-BR (Permanent decision #2).
  - Do not refactor surrounding code.
  - `git add <file>`
- When done: `git commit --no-edit` (if merge didn't auto-commit).

# Step 4B: Selective (CHERRY-PICK)

- `git log --oneline $BASE..upstream/$UPSTREAM_BRANCH`
- Ask which hashes.
- `git cherry-pick <hash1> <hash2> …`

On conflict:
- Resolve markers, `git add`, `git cherry-pick --continue`.
- `git cherry-pick --abort` to stop.

# Step 4C: Rebase (opt-in)

- `git rebase upstream/$UPSTREAM_BRANCH`

On conflict: resolve, `git add`, `git rebase --continue`. If > 3 rounds of conflicts,
`git rebase --abort` and recommend merge.

# Step 5: Validation

Run in order:
- `swift build` — this fork uses SwiftPM directly, no `npm`/`package.json`. If the current
  environment has no Swift toolchain (e.g. this session is Linux/container-based), say so
  explicitly instead of silently skipping — tell the user to run it locally before trusting
  the merge.
- `swift test --filter VectorTests` — the dictionary contract; matches what `macos.yml` runs
  in CI.

**Note:** `make app` (the release-shaped build, with codesign) is not part of this
validation — it needs a real macOS host and was never exercised by CI either. If the merge
touched `Makefile`, `Package.swift`, or `Resources/`, tell the user to run `make app` locally
before tagging a release.

**Note:** if `Package.swift` changed, diff the FluidAudio (or any) dependency version pin
against the previous one and mention it — a version bump can change `ParakeetEngine.swift`'s
API surface.

# Step 6: Targeted sweeps (this repo's equivalent of a breaking-changes check)

There's no `CHANGELOG.md` here, so skip the `[BREAKING]`-marker parse from the Boop version
of this skill. Instead, run these checks unconditionally — they catch the ways this fork's
permanent decisions come back without ever producing a merge conflict:

1. **Windows/shared residue:**
   `git diff --stat pre-upgrade-$HASH-$TIMESTAMP..HEAD -- windows/ shared/ .github/workflows/windows.yml`
   Any non-empty output is a violation of Permanent decision #1 — remove it before finishing.

2. **English string residue:** `grep -rn '"[A-Z][a-z].*[a-z]\.\?"' Sources/MurmurYouTube/UI/*.swift Sources/MurmurYouTube/MurmurYouTubeApp.swift`
   scoped to the files the merge actually touched. Anything that looks like an English
   sentence (not a proper noun, not an SF Symbols name) is Permanent decision #2 waiting to
   ship untranslated — flag it for translation.

3. **`TranscriptionEngine` protocol drift:**
   `git diff pre-upgrade-$HASH-$TIMESTAMP..HEAD -- Sources/MurmurYouTube/Transcription/TranscriptionEngine.swift`
   Any change here means checking `ElevenLabsEngine.swift` and `HCaptchaSolver.swift` still
   satisfy the protocol, and that the engine-wiring sites in Permanent decision #4 still list
   `.elevenlabs` — none of that shows up as a conflict on its own.

4. **Ported-feature files still present:**
   confirm `Support/UpdateManager.swift`, `Core/KeyCombination.swift`, `UI/HotkeyRecorder.swift`,
   `UI/NotchPanel.swift`, `UI/NotchIndicatorView.swift`, `UI/NotchShape.swift`, and
   `Support/FileLog.swift` still exist and are still referenced (`grep -rl` each symbol name
   from `MurmurYouTubeApp.swift` and `DictationController.swift`). A merge that takes
   upstream's whole `DictationController.swift` or `HotkeyMonitor.swift` "to resolve
   conflicts faster" silently deletes the hybrid mode and the notch overlay's wiring even
   though the files themselves survive untouched.

5. **`AppleSpeechEngine` locale:**
   `grep -n 'Locale(identifier: "pt-BR")' Sources/MurmurYouTube/Transcription/AppleSpeechEngine.swift`
   Must still be there (Permanent decision #3).

Report every hit from 1–5 to the user before Step 7, even if you already fixed it — they
should know what almost regressed.

# Step 7: Summary + rollback

Print:
- **Rollback tag:** `pre-upgrade-<HASH>-<TIMESTAMP>`
- **New HEAD:** `git rev-parse --short HEAD`
- **Upstream HEAD:** `git rev-parse --short upstream/$UPSTREAM_BRANCH`
- **Conflicts resolved:** list, if any
- **Sweep findings from Step 6:** list, even the ones already fixed
- **Validation result:** `swift build` / `swift test --filter VectorTests` outcome, or "not
  run — no Swift toolchain in this environment, run locally before trusting this merge"

Tell the user:
- Rollback: `git reset --hard pre-upgrade-<HASH>-<TIMESTAMP>`
- Backup branch also exists: `backup/pre-upgrade-<HASH>-<TIMESTAMP>`
- If `Makefile`/`Package.swift`/`Resources/` changed: run `make app CONFIG=release` locally
  before the next tag — that path has never been exercised by this merge or by CI.
