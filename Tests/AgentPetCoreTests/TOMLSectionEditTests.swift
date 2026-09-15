import Foundation
import Testing
@testable import AgentPetCore

@Suite("TOML block edits")
struct TOMLSectionEditTests {

    private let block = TOMLBlock(
        header: "[compat.claude]",
        lines: ["hooks = false"],
        comments: ["# written by the test"]
    )

    @Test("append on an empty file writes just the block")
    func appendEmpty() throws {
        let (result, added) = try TOMLSectionEdit.appended(block, to: "")
        #expect(result == block.text)
        #expect(added == block.text)
    }

    @Test("append gives the block a line of its own, whatever the tail looked like")
    func appendSeparates() throws {
        let bare = try TOMLSectionEdit.appended(block, to: "model = \"x\"")
        #expect(bare.result.hasPrefix("model = \"x\"\n\n"))
        #expect(bare.result.hasSuffix(block.text))
        #expect(bare.added == "\n\n" + block.text)

        let terminated = try TOMLSectionEdit.appended(block, to: "model = \"x\"\n\n")
        #expect(terminated.result == bare.result, "one blank line, not two")
        #expect(terminated.added == block.text)
    }

    @Test("an existing header of any spelling refuses the append")
    func refusesExisting() {
        for existing in [
            "[compat.claude]\nhooks = true\n",
            "[compat.claude]",
            "  [compat.claude]  \n",
            "compat.claude.hooks = false\n",   // a dotted key defines the table too
        ] {
            #expect(throws: TOMLEditError.sectionExists("compat.claude")) {
                _ = try TOMLSectionEdit.appended(block, to: existing)
            }
        }
    }

    @Test("a comment or a longer name mentioning the header is not the header")
    func nearMissesDoNotRefuse() throws {
        for existing in [
            "# [compat.claude] is configured elsewhere\nmodel = \"x\"\n",
            "[compat.claude.extra]\nkey = 1\n",
        ] {
            let (result, _) = try TOMLSectionEdit.appended(block, to: existing)
            #expect(result.hasSuffix(block.text))
        }
    }

    @Test("removal takes back exactly the bytes that were added")
    func removalRoundTrip() throws {
        let original = "model = \"x\"\n"
        let (result, added) = try TOMLSectionEdit.appended(block, to: original)
        #expect(try TOMLSectionEdit.removing(added, from: result) == original)
    }

    @Test("removal refuses when the bytes are no longer there")
    func removalRefuses() {
        #expect(throws: TOMLEditError.blockMissing) {
            _ = try TOMLSectionEdit.removing(block.text, from: "model = \"x\"\n")
        }
    }
}
