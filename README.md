<p align="center">
  <img src="Resources/AppIcon-512.png" width="132" alt="Agent Pet Runtime: a round-faced pet inside a golden ring, on orange">
</p>

# Agent Pet Runtime

**English** · [简体中文](README.zh-CN.md)

A macOS desktop pet that reacts to what your CLI coding agents are doing.

Claude Code hits a permission prompt and the pet raises a paw. A task finishes
and it celebrates, then goes back to idling. Move it around and it walks the way
you drag it. Leave it alone and it looks at your cursor, in sixteen directions.

It is not a toy bolted onto a log parser. Agent state is modelled properly, the
bridge is measured and bounded, and nothing is recorded that should not be.

```
   Claude Code ─┐
   Codex       ─┤          spawns          ┌──────────────┐
   Grok        ─┼──────► agentpet-hook ───►│    socket    │
   Pi          ─┘          (~5 ms)         └──────┬───────┘
                                                  │
                       ┌──────────────────────────▼──────────────────────┐
                       │  normalize → activity engine → animation → pet  │
                       └─────────────────────────────────────────────────┘
```

---

## Install

```bash
brew tap dncore/agent-pet-runtime
brew install --cask agent-pet-runtime
```

The app is ad-hoc signed rather than notarised, so the cask strips macOS's
quarantine attribute on install. If Gatekeeper still objects:

```bash
xattr -dr com.apple.quarantine "/Applications/AgentPet.app"
```

<details>
<summary>Or build from source</summary>

```bash
git clone https://github.com/dncore/agent-pet-runtime.git
cd agent-pet-runtime
swift build -c release
./Scripts/build-app.sh          # assembles AgentPet.app
open build/AgentPet.app
```

Requires macOS 14+ and Swift 6.1+ (Xcode 16.4 or newer).

</details>

The cask is generated from
[`homebrew/agent-pet-runtime.rb.template`](homebrew/agent-pet-runtime.rb.template)
on every release and pushed to
[dncore/homebrew-agent-pet-runtime](https://github.com/dncore/homebrew-agent-pet-runtime).
Edit the template here, not the tap.

---

## Connecting your agents

Nothing is configured until you say so. Either use the menu bar, or:

```bash
swift run AgentPet --status                    # what is installed and configured
swift run AgentPet --configure claude-code     # install the hooks
swift run AgentPet --unconfigure claude-code   # remove exactly what it wrote
```

**No restart is required.** Claude Code re-reads `~/.claude/settings.json` on
every hook dispatch, so hooks added mid-session take effect on the next event.
Sessions running long jobs are not interrupted. (Verified by adding
`SubagentStart`/`SubagentStop` to a session that had been running for hours and
watching them fire.)

Only Claude Code is configurable today. Grok's hooks live in TOML and Codex's
`notify` is an argv array; neither is something the JSON transaction can edit
safely, so those agents are detected and reported as *not configurable* rather
than half-supported.

### What configuring does

It adds hook lines to `~/.claude/settings.json` and nothing else:

- **Backed up first.** The previous file is copied to the runtime's backup
  directory before anything is written.
- **Atomic.** Written to a temporary file and renamed, so a reader sees the old
  file or the new one, never a half-written one.
- **Idempotent.** Running Configure twice changes nothing.
- **Reversible.** Remove Integration deletes only the lines the runtime wrote.
  Hook lines belonging to other tools — and there are usually several — are
  left alone.
- **Concurrency-aware.** Claude Code writes that file itself. If it changes
  between read and write, the edit is abandoned rather than clobbering it.

It never touches model settings, credentials, or prompts.

---

## How agent state is read

An agent's state is a small state machine driven by hook events. The mapping is
the part most implementations get wrong, so it is spelled out here.

| Agent says | Pet shows | Why |
|---|---|---|
| `PermissionRequest` | **waiting** | The only event meaning *the agent cannot proceed without you* |
| `PreToolUse` / `PostToolUse` / `UserPromptSubmit` | running | Work in progress |
| `Stop` | celebrating, then idle | Fires at the end of *every turn*, not the session |
| `TaskCompleted` | celebrating | An actual task finished |
| `StopFailure` | failed | A failed turn is not a successful one |
| `SessionEnd` | *(removed)* | Session over |

Three details that only show up against a real agent:

**`Notification` is a grab bag.** It carries `permission_prompt`, `idle_prompt`,
`auth_success`, and `elicitation_dialog`, distinguished only by a field. Treating
all of it as "waiting for input" leaves the pet permanently asking for attention
as soon as you have more than one session open. Only `permission_prompt` maps;
the rest change nothing.

**`Stop` lies when a subagent is running.** It fires whenever the main agent
yields, which happens while a background subagent is still working. The payload
lists `background_tasks`; if one is still running, the turn has not finished.

**Grok reads Claude Code's config.** Grok Build scans and trusts
`~/.claude/settings.json`, so hooks installed there fire on Grok events too. The
shim checks `GROK_HOOK_NAME` and re-labels them rather than reporting every Grok
session as Claude Code.

---

## How the pet animates

The published pet contract defines nine standard animation rows plus sixteen
gaze poses, each with **per-frame timings in milliseconds**. They are not
uniform: the authored `idle` is `280, 110, 110, 140, 140, 320` — a breath, with
the ends held two to three times as long as the middle — and Codex plays it six
times slower, which is what this runtime plays too. A single frame rate cannot
reproduce any of it, so the runtime stores a duration per frame.

Playback follows Codex's shape exactly: a state's row plays **three times** and
then hands over to the idle row, which loops from there. A pet that repeated
its working pose for as long as the agent worked would be a twitch; this one
does its bit and then breathes, and the message beside it is what keeps saying
what is happening. When the system asks for reduced motion, everything holds a
single frame.

Playback is layered, first match wins:

| Layer | Driven by |
|---|---|
| 1. Dragging | which way you are moving it — `running-left` / `running-right` |
| 2. A playing gesture | one-shots: `jumping`, `waving` |
| 3. Agent state | the table above |
| 4. Gaze | where your pointer is — sixteen poses, 22.5° apart |
| 5. Idle | the fallback |

Dragging outranks everything: you are holding it. Gaze only applies when the pet
would otherwise be idle, and falls back while the pointer is too close to give a
direction — the contract's "no-vector deadzone".

## What the pet says

Beside the animation, the pet carries the message element Codex's own pet has:
a short status above the sprite, taken from the same vocabulary — **Running**
(with "Thinking" under it), **Needs input** when an approval is waiting (with
the tool it is for), **Ready** when a turn finishes, **Blocked** when one
fails. Each message expires on Codex's own clock — three minutes for work, an
hour for a failure, a day for a pending decision, a week for a finished turn —
and the window grows upward to fit it, so the pet itself never moves.

The second line carries what the event knows: which tool an approval is
waiting on, what failed, and — when a turn finishes — a preview of the
assistant's last message, which Claude Code hands to hooks as
`last_assistant_message` and Codex shows the same way. It is tidied like
Codex's (whitespace collapsed, cut to 200 characters), it stays in memory, and
it never reaches a log file. Nothing you typed is ever shown.

---

## Where pets come from

Pets belong to Codex. The runtime reads Codex's own pets directory —
`$CODEX_HOME/pets`, or `~/.codex/pets` — and never writes to it:

```sh
npx codex-pets add <pet-id>     # install from codex-pets.net; run again to update
rm -rf ~/.codex/pets/<pet-id>   # remove: a pet is a folder, deleting it is the whole operation
```

Any folder in there with a `pet.json` and a spritesheet works, however it got
there — the hatch-pet skill, a download you unzipped by hand, a friend's
package. Codex's older `~/.codex/avatars/` directory is read too, for pets
packaged with an `avatar.json`, and a manifest may leave out its id or
spritesheet path exactly as Codex's loader allows. The Pet Manager lists
exactly those directories, previews each pet, and puts the one you choose on
your desktop; it does not install, import, or delete anything itself, so the
app and your terminal Codex can never disagree about what is installed. Your
choice is remembered across launches.

---

## Performance

The shim runs on the agent's critical path, once per tool call, so this is the
number that decides whether the design is viable at all.

| | P50 | P95 | P99 | max |
|---|---|---|---|---|
| Runtime running | **4.33 ms** | 6.27 ms | 6.59 ms | 6.90 ms |
| Runtime not running | 3.81 ms | 5.62 ms | 6.51 ms | 6.53 ms |

Budget is P50 < 5 ms, P99 < 25 ms, over 500 samples. Swift with Foundation
starts in 3.72 ms against C's 2.23 ms; the 1.2 ms buys a JSON envelope that can
be debugged with `nc -U`.

**The shim always exits 0.** Claude Code treats a non-zero hook exit as
meaningful and will change agent behaviour in response — a pet that alters your
agents would be a far worse bug than a pet that misses an event.

---

## Privacy

Local only. Nothing is uploaded, and there is no cloud component.

The runtime reads session ids, working directories, and event names. It does
**not** read prompts, model output, or source code — not filtered, simply never
read. The integration records it writes to disk contain hook commands and
timestamps, and nothing else.

`--log-events` writes a diagnostic capture, off by default. It keeps only the
fields diagnosis needs and drops `tool_input`, `tool_response`, and
`transcript_path` — an allowlist, so a field a future agent build adds cannot
leak into a log by default. Files are written `0600`.

---

## Development

```bash
swift build && swift test        # 347 tests
swift run AgentPet               # run it

swift run AgentPet --diagnose                      # what pets are discoverable, and why
swift run AgentPet --diagnose --export-frames /tmp/frames
swift run AgentPet --selftest                      # render every state, measure the output
```

`--selftest` exists because screenshots are not always available: without Screen
Recording permission, `screencapture` returns only wallpaper. It draws each
state through the live view and counts non-transparent pixels in the backing
store instead, and also asserts the pet is grabbable — a pet that renders
perfectly but cannot be dragged looks identical to a working one.

```
Sources/AgentPetCore/     Pure logic. No AppKit, so it is all testable headlessly.
├── Domain/               AgentState, AgentEvent, AgentActivity, Confidence
├── Activity/             ActivityEngine — priority, aging, focus hold, dwell
├── Bridge/               Envelope, framing, server, normalizer, hook setup
├── Pet/                  Manifest, compatibility profiles, validation, decoding
├── Integration/          Config transaction, configurators, detection
├── Runtime/              AnimationResolver, drag geometry
├── Settings/             AppConfig
└── Diagnostics/          Transition log, event capture, exportable bundle

Sources/AgentPetApp/      AppKit + SwiftUI: floating pet, manager window, menu bar
Sources/agentpet-hook/    The shim agents execute. Must always exit 0.
```

`docs/SPEC-REVIEW.md` is the design review this was built from — what held up,
what did not, and the evidence for each. `docs/ARCHITECTURE.md` is the
corrected specification.

---

## Status

| | |
|---|---|
| Core, pet loading, validation, activity engine | done |
| Floating pet, drag, gaze, position memory | done |
| Event bridge, verified against the real binary | done |
| Pet Manager: list Codex's pets, preview, pick one | done — read-only; pets are installed with Codex's own tooling |
| Agent Integrations: detect, configure, remove | Claude Code only |
| Activity Center, Settings, diagnostics export | done |
| Grok / Codex / Pi configuration | not built — their formats need their own configurators |
| Window focusing | opens the project folder; hooks carry no terminal identity |

---

## License

MIT. See [LICENSE](LICENSE).
