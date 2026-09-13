import Foundation
import Testing
@testable import AgentPetCore

@Suite("Atlas geometry")
struct AtlasGeometryTests {

    @Test("V1 matches the published contract")
    func v1Geometry() {
        let p = CompatibilityProfile.openAICodexV1
        #expect(p.columns == 8)
        #expect(p.rows == 9)
        #expect(p.cellWidth == 192)
        #expect(p.cellHeight == 208)
        #expect(p.atlasWidth == 1536)
        #expect(p.atlasHeight == 1872)
    }

    @Test("V2 keeps the cell size and column count, adding rows")
    func v2Geometry() {
        let p = CompatibilityProfile.openAICodexV2
        #expect(p.columns == 8)
        #expect(p.rows == 11)
        #expect(p.cellWidth == 192)
        #expect(p.cellHeight == 208)
        #expect(p.atlasWidth == 1536)
        #expect(p.atlasHeight == 2288)
    }

    @Test("box geometry is consistent: width = columns x cellWidth")
    func geometryIsConsistent() {
        for p in CompatibilityProfile.allCases {
            #expect(p.atlasWidth == p.columns * p.cellWidth)
            #expect(p.atlasHeight == p.rows * p.cellHeight)
        }
    }

    @Test("sizes measured on disk resolve to the right profile")
    func realSizesResolve() {
        #expect(CompatibilityProfile.matching(width: 1536, height: 1872) == .openAICodexV1)
        #expect(CompatibilityProfile.matching(width: 1536, height: 2288) == .openAICodexV2)
        #expect(CompatibilityProfile.matching(width: 1536, height: 1873) == nil)
        #expect(CompatibilityProfile.matching(width: 0, height: 0) == nil)
    }
}

@Suite("Animation track contract")
struct AnimationTrackTests {

    @Test("V1 row 0-8 names and frame counts match the published contract", arguments: [
        (0, "idle", 6), (1, "running-right", 8), (2, "running-left", 8),
        (3, "waving", 4), (4, "jumping", 5), (5, "failed", 8),
        (6, "waiting", 6), (7, "running", 6), (8, "review", 6),
    ])
    func v1Contract(row: Int, name: String, frames: Int) {
        let track = CompatibilityProfile.openAICodexV1.track(atRow: row)
        #expect(track?.name == name)
        #expect(track?.frameCount == frames)
    }

    @Test("frame counts never exceed the column count")
    func framesFitInColumns() {
        for p in CompatibilityProfile.allCases {
            for track in p.tracks {
                #expect(track.frameCount <= p.columns,
                        "\(p.rawValue) row \(track.row) needs \(track.frameCount) frames but has \(p.columns) columns")
            }
        }
    }

    @Test("every track occupies a distinct row inside the atlas")
    func rowsAreUniqueAndInBounds() {
        for p in CompatibilityProfile.allCases {
            let rows = p.tracks.map(\.row)
            #expect(Set(rows).count == rows.count)
            for row in rows { #expect(row >= 0 && row < p.rows) }
        }
    }

    @Test("V2 keeps V1's nine rows identical as a prefix")
    func v2ExtendsV1() {
        let v1 = CompatibilityProfile.openAICodexV1
        let v2 = CompatibilityProfile.openAICodexV2
        for row in 0..<v1.rows {
            #expect(v2.track(atRow: row)?.name == v1.track(atRow: row)?.name)
            #expect(v2.track(atRow: row)?.frameCount == v1.track(atRow: row)?.frameCount)
            // Timings must match too — a V1 and a V2 pet of the same character
            // should not animate at different speeds.
            #expect(v2.track(atRow: row)?.frameDurations == v1.track(atRow: row)?.frameDurations)
        }
    }

    @Test("V2's look rows are used, not spare capacity")
    func lookRowsAreUsed() {
        let v2 = CompatibilityProfile.openAICodexV2
        // Rows 9 and 10 are the sixteen gaze poses, so all eight columns of
        // each are used and none may be required to stay clear.
        #expect(v2.track(atRow: 9)?.frameCount == 8)
        #expect(v2.track(atRow: 10)?.frameCount == 8)
        #expect(v2.requiredRows.contains(9))
        #expect(v2.requiredRows.contains(10))
        #expect(!v2.rowsRequiringCleanSurplus.contains(9))
        #expect(!v2.rowsRequiringCleanSurplus.contains(10))
    }

    @Test("every V1 row is a required row")
    func allV1RowsRequired() {
        let v1 = CompatibilityProfile.openAICodexV1
        #expect(v1.requiredRows == Array(0..<9))
    }

    @Test("track duration is the sum of its per-frame timings")
    func duration() {
        // Idle as Codex plays it: the authored 1.10s breath, six times slower.
        let idle = CompatibilityProfile.openAICodexV1.track(named: "idle")
        #expect(abs((idle?.duration ?? 0) - 6.60) < 0.0001)
    }
}

@Suite("AgentState to animation track mapping")
struct StateToTrackTests {

    @Test("each state resolves to a track that exists in both profiles", arguments: AgentState.allCases)
    func everyStateResolves(state: AgentState) {
        for p in CompatibilityProfile.allCases {
            let track = p.track(named: state.animationTrackName)
            #expect(track != nil, "\(state) -> \(state.animationTrackName) missing in \(p.rawValue)")
        }
    }

    @Test("state mapping table", arguments: [
        (AgentState.idle, "idle"),
        (.running, "running"),
        (.waitingInput, "waiting"),
        (.waitingApproval, "waiting"),
        (.completed, "review"),
        (.failed, "failed"),
        (.paused, "idle"),
        (.unknown, "idle"),
    ])
    func mapping(state: AgentState, track: String) {
        #expect(state.animationTrackName == track)
    }

    @Test("directional locomotion rows are never chosen by state")
    func locomotionNotStateDriven() {
        for state in AgentState.allCases {
            #expect(state.animationTrackName != "running-left")
            #expect(state.animationTrackName != "running-right")
        }
    }

    @Test("both waiting states share one row — the atlas only has one")
    func waitingStatesShareRow() {
        #expect(AgentState.waitingInput.animationTrackName
                == AgentState.waitingApproval.animationTrackName)
    }

    @Test("the state track for running is row 7, not the directional rows")
    func runningUsesRowSeven() {
        let track = CompatibilityProfile.openAICodexV1.track(named: AgentState.running.animationTrackName)
        #expect(track?.row == 7)
    }
}

@Suite("Priority classes")
struct PriorityClassTests {

    @Test("priority classes sort by urgency")
    func ordering() {
        #expect(PriorityClass.attention < .failure)
        #expect(PriorityClass.failure < .active)
        #expect(PriorityClass.active < .settled)
        #expect(PriorityClass.settled < .inactive)
    }

    @Test("state to priority class", arguments: [
        (AgentState.waitingInput, PriorityClass.attention),
        (.waitingApproval, .attention),
        (.failed, .failure),
        (.running, .active),
        (.completed, .settled),
        (.idle, .inactive),
        (.unknown, .inactive),
        (.paused, .inactive),
    ])
    func mapping(state: AgentState, expected: PriorityClass) {
        #expect(state.priorityClass == expected)
    }
}

@Suite("Stale timeouts")
struct StaleTimeoutTests {

    @Test("states that can go stale declare where they degrade to", arguments: [
        (AgentState.running, 30.0, AgentState.unknown),
        (.unknown, 60.0, .idle),
        (.waitingApproval, 300.0, .unknown),
        (.failed, 600.0, .idle),
    ])
    func staleStates(state: AgentState, timeout: TimeInterval, successor: AgentState) {
        #expect(state.staleTimeout == timeout)
        #expect(state.staleSuccessor == successor)
    }

    @Test("a user-facing wait never times out — they may be away for a long time", arguments: [
        AgentState.waitingInput, .idle, .paused,
    ])
    func neverStale(state: AgentState) {
        #expect(state.staleTimeout == nil)
        #expect(state.staleSuccessor == nil)
    }

    @Test("completed settles rather than sticking forever")
    func completedSettles() {
        // Claude Code fires Stop at the end of every turn. A state that never
        // expires would leave every session reading "completed" indefinitely.
        #expect(AgentState.completed.staleTimeout == 4)
        #expect(AgentState.completed.staleSuccessor == .idle)
    }

    @Test("a stale timeout always has a successor and vice versa", arguments: AgentState.allCases)
    func timeoutAndSuccessorAgree(state: AgentState) {
        #expect((state.staleTimeout == nil) == (state.staleSuccessor == nil))
    }

    @Test("a state never degrades into itself")
    func successorDiffersFromSelf() {
        for state in AgentState.allCases {
            if let next = state.staleSuccessor { #expect(next != state) }
        }
    }
}
