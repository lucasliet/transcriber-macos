# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

Push-to-talk dictation for macOS. Hold a key, talk, release, and cleaned-up text is typed
into whatever had focus. Swift 6, SwiftUI, no Xcode project — everything is built with
SwiftPM via the `Makefile`.

Speech comes from one of three engines: Apple's on-device `SpeechAnalyzer`, Parakeet
(FluidAudio, on the Neural Engine), or ElevenLabs Scribe over the network — see
[docs/ELEVENLABS.md](docs/ELEVENLABS.md) for that last one, it runs with no API key.

**The app works and is in daily use.**

> This started as a fork of [`per-simmons/murmur-youtube`](https://github.com/per-simmons/murmur-youtube),
> which also carried a Windows/Avalonia reimplementation and a cross-platform dictionary
> contract test shared between the two. Both were removed here: this repo is macOS-only, and
> `dictionary-test-vectors.json` now lives solely under `Tests/MurmurDictionaryTests/` with
> nothing on the other side to keep in sync.

---

## The one rule that matters

**`Tests/MurmurDictionaryTests/dictionary-test-vectors.json` is the specification for
correction behaviour.** Change how corrections work by changing the vectors first, watch
`VectorTests` go red, then make it green — not the other way around. "Fixing" a failing
vector by loosening it instead of fixing the corrector is how silent regressions get in.

```bash
swift test --filter VectorTests
```

---

## Things that look like bugs and are not

**`swift build` fails with "input file was modified during the build."** The repo lives in an
iCloud-synced folder and the sync engine touches files mid-compile. **Always build with
`make`**, which uses `--scratch-path` outside the synced tree. A bare `swift build` also
writes a `.build/` directory into iCloud, which makes every subsequent build minutes slower.
If you see this error, wait a few seconds and retry.

**Compare mode doesn't type anything.** By design — `Settings.compareMode` runs every engine
on one recording and shows them side by side. If both injected, two transcripts would fight
over one text field. This is the single most confusing behaviour in the app.

**The timing column isn't comparing like with like.** Apple and Parakeet are timed on local
compute with the clock started *after* model load. ElevenLabs' number is a network round
trip, and Wispr Flow's is its own `e2eLatency`, which includes a round trip *and* its
cleanup pass. Don't present them as one ranking.

**Compare mode sends audio to ElevenLabs even when a local engine is selected.** Every
engine runs, and ElevenLabs is one of them. That is the point of the mode, but it is the
only place where comparing costs a network call — say so before suggesting someone leave it
on.

**Almost everything in `ElevenLabsEngine.swift` that looks like tidy-up is load-bearing.**
The socket URL is concatenated rather than built with `URLComponents` (which
percent-encodes the hCaptcha JWT and gets the connection rejected). The batch request sends
browser-shaped headers the unauthenticated endpoint checks. The commit path waits for the
transcript to stop changing rather than taking the first final frame, because the first one
routinely omits the last chunk of audio. `docs/ELEVENLABS.md` explains each one — read it
first.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

**Mutating `@State` inside a `Canvas` draw closure floods the log and corrupts state.** The
VU meter keeps its needle physics in a plain reference type the view merely holds, which is
invisible to SwiftUI's state graph. Don't "clean that up" into `@State`.

---

## Design system

`Sources/MurmurYouTube/UI/DesignSystem.swift` defines every colour, size, radius, duration
and material token. **Views must not contain literal values.** If a component needs a number
that isn't a token, add the token rather than inlining it.

The direction is 1980s field recorders — Sony TC-D5, Marantz PMD, Nakamichi, Braun. Silver
face in light appearance, black face in dark. Two rules that are not negotiable:

- **Red means recording.** Nothing else in the app is red.
- **Amber and green are instrumentation only** — level meters, never UI chrome.

Explicitly ruled out: neon, vaporwave, synthwave, purple/pink gradients, glowing text, chrome
lettering, grid horizons. There are **no gradients anywhere**; depth comes from flat panels,
hairline bevels and procedurally-drawn brushed grain.

---

## macOS specifics

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur-youtube
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly.

**Don't run the `.app` from the repo folder.** It's iCloud-synced and the sync engine can
corrupt the signature. `make install` puts the running copy in `/Applications`.

---

## Regex, if you touch the dictionary

Stay inside the safe, boring subset: `\b`, `\d`, `\w`, `\s`, character classes,
greedy/lazy quantifiers, alternation, `(?<name>…)`, fixed-length lookbehind, lookahead,
`\p{L}`, and `$1`–`$9` in replacements. `NSRegularExpression` uses ICU under the hood;
nothing here depends on that beyond the safe subset, but there's no second implementation
left to catch a divergence if you wander outside it.

---

## What isn't built

1. **Command Mode** — select text, hold a second key, "make this more formal."
2. **Onboarding** — a first-run window walking through the macOS permissions.
3. **Notarization** — the app is unsigned for distribution; users meet Gatekeeper on
   first open.

## Releasing

`.github/workflows/release.yml` fires on a `v*` tag. It generates notes with the Claude
Code CLI (Haiku, falling back to z.ai/GLM, then to the last commit message) from the
commits since the previous tag, builds with `make app CONFIG=release`, and attaches
`MurmurYouTube.zip` to a GitHub Release. The runner has no Developer ID, so the
`Makefile`'s `SIGN_ID` falls back to ad-hoc — released builds are ad-hoc signed and users
meet Gatekeeper on first open.

**The version stamped into `Resources/Info.plist` is what `UpdateManager` compares against
the latest tag**, numerically. Ship a tag whose version isn't greater than the previous one
and every installed copy silently decides it is already up to date.

`claude-code-review.yml` reviews PRs with the same two-provider fallback. `macos.yml` and
`windows.yml` are the contract checks and run on push/PR; they do not publish anything.

---

## The two overlays and the two "is it running" flags

`DictationController.State` has three predicates and they are not interchangeable:

- **`isActive`** — the overlay should be on screen. Stays true through `.success`/`.error`,
  which linger about three seconds.
- **`isBusy`** — a new recording may not start. False during `.success`/`.error`, so the
  next hold never waits for the overlay to clear.
- **`isCapturing`** — the mic is open. Drives the elapsed timer.

Anything that means "am I recording" — the Record button, the Rec lamp, the menu bar glyph,
the counter — must read `isBusy`. Using `isActive` there leaves the button stuck on "Parar"
for three seconds after every dictation, and pressing it then calls stop on a controller
that isn't recording.

**A recording can outlive the keypress.** In `.hybrid` (the default) a tap under a second
latches the mic open until the next press, so `state.isCapturing` true with the key
physically up is normal, not a stuck tap. Anything that stops a recording without going
through the tap — the Record button, `fail`, `cancelDictation` — has to call
`hotkey.resetLatch()`, or the monitor still believes a latch is live and reads the user's
next hold as the press that ends it.

---

## What no amount of CI can verify

CI has no interactive desktop and no real microphone, so it can build, sign and run the
dictionary contract, but it cannot confirm: text injection landing in a real foreground app,
microphone format negotiation and the macOS privacy prompt, the `CGEventTap` firing on a
physical keypress, or Parakeet/ElevenLabs transcribing actual speech. Those need a person
holding the key and talking — see AGENTS.md's own Testing Guidelines note above.
