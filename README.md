# Agent Pet Runtime

A macOS desktop pet that reacts to what your CLI coding agents are doing.

This is a v0.1 implementation of the `Agent_Pet_Runtime_v0.1.md` design. The
design was reviewed against reality before implementation, and several parts of
it changed — see `docs/SPEC-REVIEW.md` for what held up, what did not, and the
evidence for each.

## Status

| Milestone | State |
|---|---|
| Core domain, pet loading, validation, activity engine, animation | **done** — 143 tests |
| Floating pet renderer (`NSPanel`) | **done** — renders, drags, remembers position |
| Agent event bridge (`agentpet-hook` + socket) | not started |
| Pet Manager UI | not started |
| Agent Integrations UI | not started |

The desktop pet currently animates from an in-process activity engine. Real
agent events reach it once the bridge lands; until then the menu bar has a
**Simulate Agent Event** submenu that feeds synthetic events through the same
engine, which is also the "Test Integration" path the design calls for.

## Running

```bash
swift build
swift run AgentPet
```

The menu bar shows a 🐾 icon: pick a pet, preview any animation, simulate agent
events, or quit. Drag the pet anywhere; the position is remembered per-user and
restored on next launch, but ignored if it would land off-screen.

### Self-checks

```bash
swift run AgentPet --diagnose              # what pets are discoverable, and why
swift run AgentPet --diagnose --export-frames /tmp/frames
swift run AgentPet --selftest              # render each state, measure the output
swift test                                 # the real test suite
```

`--selftest` renders every agent state through the live view and counts
non-transparent pixels in the backing store. It exists because `screencapture`
returns only wallpaper without Screen Recording permission, so a pixel count
from the view's own buffer is the only dependable evidence that anything is
being drawn.

## Layout

```
Sources/AgentPetCore/       Pure logic. No AppKit, so it is all testable headlessly.
├── Domain/                 AgentState, AgentEvent, AgentActivity, Confidence
├── Activity/               ActivityEngine — priority, aging, focus hold, dwell
├── Pet/                    Manifest parsing, compatibility profiles, validation
│   └── Validation/         Manifest, atlas, path safety, payload
└── Runtime/                AnimationResolver

Sources/AgentPetApp/        AppKit shell: NSPanel, view, menu bar, diagnostics.
Tests/AgentPetCoreTests/    143 tests. Fixtures copied verbatim from real packages.
```

## Design decisions worth knowing

**The event bridge is not a server the agents connect to.** Codex, Claude Code
and Grok all deliver hooks by spawning a process; Pi delivers in-process. The
bridge is therefore a shim the agent executes plus a socket it writes to. See
`docs/ARCHITECTURE.md` §1.

**Hooks sit on the agent's critical path.** The shim must always exit 0.
Claude Code treats a non-zero hook exit as meaningful and will change agent
behaviour in response — a hung or crashed pet would alter the user's agents,
which is exactly what the design's non-invasiveness principle forbids.

**Only four of the nine atlas rows are driven by agent state.** `waving`,
`jumping` and `review` are gesture tracks, and `running-left`/`running-right`
are locomotion. Treating all nine as state rows is a category error.

**V2 atlases load rather than being rejected.** `spriteVersionNumber: 2`
(1536×2288) exists in the wild — including in a pet already installed on this
machine. Rows 0–8 play; rows 9–10 are reserved.

**Surplus-cell residue is a warning, not an error.** OpenAI's authoring
validator fails on any stray pixel past a row's frame count. This renderer only
samples columns `0..<frameCount`, so those pixels are unreachable and cannot
affect playback. Measurement backs this: three installed pets are clean, while
`pet-ben-hill` carries 13,560 stray pixels and still installs.

## Where pets come from

`~/.codex/pets/` is scanned as a **read-only discovery source**. The runtime
never writes to it — Codex manages that directory itself. Importing a pet into
the runtime's own store, and the provenance tracking that makes uninstall safe,
is not built yet.
