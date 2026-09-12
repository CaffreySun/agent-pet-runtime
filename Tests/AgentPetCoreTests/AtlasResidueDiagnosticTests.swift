import Foundation
import Testing
@testable import AgentPetCore

/// Measures surplus-cell residue in the real packages and reports it.
///
/// This test does not assert a particular number — the corpus is whatever the
/// machine happens to have installed. It exists so the calibration behind
/// `AtlasValidator`'s severity choice is visible and re-checkable rather than
/// a claim in a comment.
@Suite("Surplus-cell residue in real atlases", .enabled(if: RealPets.root != nil))
struct AtlasResidueDiagnosticTests {

    @Test("report residue per package so the warning threshold can be justified")
    func measureResidue() throws {
        let loader = PetPackageLoader()
        var anyResidue = false

        for (name, root) in RealPets.manifests() {
            let loaded = try loader.load(from: root)
            let residues = loaded.report.warnings.filter { $0.message.contains("unused column") }

            for warning in residues {
                anyResidue = true
                print("RESIDUE [\(name)] \(warning.message)")
            }
            if residues.isEmpty {
                print("CLEAN   [\(name)] no surplus-cell residue")
            }
        }

        // Whatever the corpus looks like, residue must never be an error:
        // unreachable pixels are not a reason to refuse an install.
        for (name, root) in RealPets.manifests() {
            let loaded = try loader.load(from: root)
            let errorResidue = loaded.report.errors.filter { $0.message.contains("unused column") }
            #expect(errorResidue.isEmpty, "\(name) treated unreachable pixels as fatal")
        }

        if anyResidue {
            print("NOTE: at least one installed pet deviates from the published contract "
                  + "but remains installable by design.")
        }
    }
}
