import Foundation
import Testing
@testable import AgentPetCore

@Suite("App versions")
struct AppVersionTests {

    @Test("a plain version parses, and a tag's leading v does not confuse it")
    func parsing() {
        #expect(AppVersion("1.2.3")?.components == [1, 2, 3])
        #expect(AppVersion("v0.5.3")?.components == [0, 5, 3])
        #expect(AppVersion(" 0.5.3 ")?.components == [0, 5, 3])
        #expect(AppVersion("2")?.components == [2])
        #expect(AppVersion("") == nil)
        #expect(AppVersion("next") == nil)
    }

    @Test("missing components count as zero")
    func paddedComparison() {
        #expect(AppVersion("1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1.2.0.1")! > AppVersion("1.2")!)
        #expect(AppVersion("1.10")! > AppVersion("1.9")!, "ten beats nine, not string order")
    }

    @Test("a pre-release suffix does not make a version newer")
    func preRelease() {
        // Nobody upgrades from 1.0.0 to 1.0.0-beta; ordering pre-releases is a
        // problem this app does not have, so the suffix is dropped.
        #expect(AppVersion("1.0.0-beta.1") == AppVersion("1.0.0"))
        #expect(!AppVersion.isNewer("v1.0.0-beta.1", than: "1.0.0"))
        #expect(AppVersion.isNewer("v1.0.1", than: "1.0.0"))
    }

    @Test("isNewer answers the question the update check asks")
    func newer() {
        #expect(AppVersion.isNewer("v0.5.4", than: "0.5.3"))
        #expect(AppVersion.isNewer("v0.6.0", than: "0.5.9"))
        #expect(AppVersion.isNewer("v1.0.0", than: "0.99.99"))
        #expect(!AppVersion.isNewer("v0.5.3", than: "0.5.3"), "the same version is not an update")
        #expect(!AppVersion.isNewer("v0.5.2", than: "0.5.3"), "an older tag is not an update")
    }

    @Test("something unreadable never claims to be an update")
    func garbageIsNotAnUpdate() {
        #expect(!AppVersion.isNewer("nightly", than: "0.5.3"))
        #expect(!AppVersion.isNewer("v0.5.4", than: "not installed"))
        #expect(!AppVersion.isNewer("", than: ""))
    }
}
