# Agent Pet Runtime

A macOS desktop pet that reacts to what your CLI coding agents are doing.

An implementation of the `Agent_Pet_Runtime_v0.1.md` design. The design was
reviewed against reality before implementation and several parts of it changed;
see `docs/SPEC-REVIEW.md` for what held up, what did not, and the evidence.

## Status

| Milestone | State |
|---|---|
| Core domain, pet loading, validation, activity engine, animation | done |
| Floating pet renderer | done — renders, drags, remembers position |
| Agent event bridge (shim + socket) | done — verified against the real binary |
| Pet Manager (import, preview, upgrade, uninstall) | done |
| Agent Integrations (detect, configure, remove, test) | done for Claude Code |
| Activity Center | done |
| Settings, Launch at Login, diagnostics export | done |

**283 tests.** Seven of them run the compiled `agentpet-hook` binary against a
live socket rather than an in-process stand-in, because the boundary between
this app and a real agent *is* the binary.

## Running

```bash
swift build
swift run AgentPet
```

Menu bar 🐾 → **Open Pet Manager** for the full window, or use the menu
directly for pets, animation previews, and settings.

### Wiring up a real agent

Nothing is configured to talk to the bridge until you say so. Either:

```bash
swift run AgentPet --status                    # what is installed and configured
swift run AgentPet --configure claude-code     # install the hooks
swift run AgentPet --unconfigure claude-code   # remove exactly what it wrote
```

or use **Agents → Configure** in the window. Both paths run the same code.

Only Claude Code is configurable. Grok's hooks live in TOML and Codex's `notify`
is an argv array; neither is something the JSON transaction can edit safely, so
those agents are detected and reported as not configurable rather than
half-supported.

Configuration is transactional: snapshot, back up, edit in memory, re-check for
concurrent writes, write atomically, verify, and restore on any failure. Running
Configure twice changes nothing. Removing deletes only the lines the runtime
wrote — anything you wrote yourself is untouched.

### Self-checks

```bash
swift run AgentPet --diagnose                      # what pets are discoverable, and why
swift run AgentPet --diagnose --export-frames /tmp/frames
swift run AgentPet --selftest                      # render every state, measure the output
swift test
```

`--selftest` renders each agent state through the live view and counts
non-transparent pixels in the backing store. It exists because `screencapture`
returns only wallpaper without Screen Recording permission, so a pixel count
from the view's own buffer is the only dependable evidence that anything is
being drawn.

## Layout

```
Sources/AgentPetCore/          Pure logic. No AppKit, so it is all testable headlessly.
├── Domain/                    AgentState, AgentEvent, AgentActivity, Confidence
├── Activity/                  ActivityEngine — priority, aging, focus hold, dwell
├── Bridge/                    Envelope, framing, server, normalizer, hook setup
├── Pet/                       Manifest, profiles, validation, decoding, frames
├── Pets/                      Store: install, upgrade, uninstall, provenance
├── Integration/               Config transaction, configurators, detection, records
├── Runtime/                   AnimationResolver
├── Settings/                  AppConfig
└── Diagnostics/               Transition log, exportable bundle

Sources/AgentPetApp/           AppKit + SwiftUI: NSPanel pet, manager window, menu bar.
Sources/agentpet-hook/         The shim agents execute. Must always exit 0.
Tests/AgentPetCoreTests/       283 tests, fixtures copied verbatim from real packages.
```

## Measured properties

**Shim latency.** The shim runs on the agent's critical path, once per tool
call, so this decides whether the design is viable at all:

| | P50 | P95 | P99 | max |
|---|---|---|---|---|
| Runtime running | **4.33 ms** | 6.27 ms | 6.59 ms | 6.90 ms |
| Runtime not running | 3.81 ms | 5.62 ms | 6.51 ms | 6.53 ms |

Budget is P50 < 5 ms, P99 < 25 ms, over 500 samples. Swift with Foundation
starts in 3.72 ms against C's 2.23 ms; the 1.2 ms buys a JSON envelope that can
be debugged with `nc -U`.

## Design decisions worth knowing

**The event bridge is not a server the agents connect to.** Codex, Claude Code
and Grok all deliver hooks by spawning a process; Pi delivers in-process. The
bridge is a shim the agent executes plus a socket it writes to.

**The shim always exits 0.** Claude Code treats a non-zero hook exit as
meaningful and will change agent behaviour in response. A pet that alters the
user's agents would be a far worse bug than a pet that misses an event.

**Only four of the nine atlas rows are driven by agent state.** `waving`,
`jumping` and `review` are gesture tracks; `running-left`/`running-right` are
locomotion. Treating all nine as state rows is a category error.

**V2 atlases load rather than being rejected.** `spriteVersionNumber: 2`
(1536×2288) exists in the wild — including in a pet already installed on this
machine. Rows 0–8 play; rows 9–10 are reserved.

**Surplus-cell residue is a warning, not an error.** OpenAI's authoring
validator fails on any stray pixel past a row's frame count, but this renderer
only samples columns `0..<frameCount`, so those pixels are unreachable and
cannot affect playback. Measurement backs this: three installed pets are clean,
while `pet-ben-hill` carries 13,560 stray pixels and still installs.

**Install validates before it commits.** A package is fully copied and checked
in `staging/` before `pets/` is touched, so a rejected package leaves no trace —
rollback with nothing to roll back. `managedByRuntime` is the single field
deciding whether uninstall may delete, which is what makes "never delete the
user's package" implementable rather than aspirational.

**`~/.codex/pets/` is read-only.** The Codex toolchain owns that directory.
Pets found there are offered for import into the runtime's own store and
nothing ever writes back.

## Not built

- **Grok, Codex and Pi configuration.** Detected, not configurable — their
  config formats need their own configurators.
- **Codex app-server IPC.** `~/.codex/ipc/ipc.sock` may be a richer event
  source than the `notify` hook. Unverified.
- **Window focusing.** Hook payloads carry no terminal identity, so clicking an
  activity opens its project directory instead of raising a window.
  `docs/SPEC-REVIEW.md` §3.3 explains why and what the path forward is.
- **Multi Pet.** One pet on the desktop at a time.
