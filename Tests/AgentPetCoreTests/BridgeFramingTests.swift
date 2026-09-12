import Foundation
import Testing
@testable import AgentPetCore

@Suite("Bridge frame decoding")
struct BridgeFrameDecoderTests {

    @Test("one frame in one chunk")
    func singleFrame() {
        var decoder = BridgeFrameDecoder()
        let frames = decoder.append(Data("{\"a\":1}\n".utf8))
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == "{\"a\":1}")
        #expect(decoder.pendingByteCount == 0)
    }

    @Test("several frames in one chunk")
    func multipleFrames() {
        var decoder = BridgeFrameDecoder()
        let frames = decoder.append(Data("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n".utf8))
        #expect(frames.count == 3)
    }

    @Test("a frame split across chunks is reassembled")
    func splitAcrossChunks() {
        var decoder = BridgeFrameDecoder()
        #expect(decoder.append(Data("{\"hel".utf8)).isEmpty)
        #expect(decoder.pendingByteCount == 5)
        let frames = decoder.append(Data("lo\":1}\n".utf8))
        #expect(frames.count == 1)
        #expect(String(data: frames[0], encoding: .utf8) == "{\"hello\":1}")
    }

    @Test("a partial trailing frame is held back")
    func partialTrailingFrame() {
        var decoder = BridgeFrameDecoder()
        let frames = decoder.append(Data("{\"a\":1}\n{\"b\":".utf8))
        #expect(frames.count == 1)
        #expect(decoder.pendingByteCount == 5)
    }

    @Test("byte-at-a-time delivery still yields whole frames")
    func byteAtATime() {
        var decoder = BridgeFrameDecoder()
        let input = Data("{\"x\":1}\n{\"y\":2}\n".utf8)
        var collected: [Data] = []
        for byte in input {
            collected.append(contentsOf: decoder.append(Data([byte])))
        }
        #expect(collected.count == 2)
        #expect(String(data: collected[1], encoding: .utf8) == "{\"y\":2}")
    }

    @Test("empty frames are skipped")
    func emptyFramesSkipped() {
        var decoder = BridgeFrameDecoder()
        let frames = decoder.append(Data("\n\n{\"a\":1}\n\n".utf8))
        #expect(frames.count == 1)
    }

    @Test("an unbounded partial frame is discarded rather than buffered forever")
    func runawayFrameDiscarded() {
        var decoder = BridgeFrameDecoder(maximumFrameBytes: 64)
        _ = decoder.append(Data(repeating: 0x41, count: 200))
        #expect(decoder.pendingByteCount == 0)

        // The peer is still usable afterwards.
        let frames = decoder.append(Data("\n{\"ok\":1}\n".utf8))
        #expect(frames.count == 1)
    }

    @Test("real encoded envelopes survive the round trip")
    func realEnvelopeRoundTrip() throws {
        var decoder = BridgeFrameDecoder()
        var stream = Data()
        for index in 0..<3 {
            let envelope = BridgeEnvelope(
                agentID: "claude-code",
                eventName: "PreToolUse",
                receivedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                proc: BridgeProcessInfo(pid: 10, ppid: 9, tty: nil),
                rawPayload: Data(#"{"session_id":"s\#(index)","cwd":"/tmp/p"}"#.utf8)
            )
            stream.append(try envelope.encoded())
            stream.append(0x0A)
        }

        let frames = decoder.append(stream)
        #expect(frames.count == 3)

        let normalizer = EventNormalizer(profiles: AgentProfiles.all)
        let events = frames
            .compactMap { try? BridgeEnvelope.decode(from: $0) }
            .flatMap { normalizer.normalize($0) }
        #expect(events.count == 3)
        #expect(events.map(\.sessionID) == ["s0", "s1", "s2"])
    }
}

@Suite("Bridge socket location")
struct BridgeSocketLocationTests {

    @Test("the default path fits in sun_path")
    func defaultPathFits() {
        #expect(throws: Never.self) {
            try BridgeSocketLocation.validate(BridgeSocketLocation.defaultURL)
        }
    }

    @Test("an over-long path is rejected with the actual byte count")
    func longPathRejected() {
        let long = URL(fileURLWithPath: "/" + String(repeating: "d", count: 200) + "/bridge.sock")
        #expect(throws: BridgeSocketError.self) {
            try BridgeSocketLocation.validate(long)
        }
    }
}
