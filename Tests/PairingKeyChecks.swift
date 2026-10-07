// Run: swiftc -swift-version 5 Sources/PairingKey.swift Tests/PairingKeyChecks.swift -o /tmp/pk && /tmp/pk
// Uses a unique disposable keychain service; the real "uc-steer" item is never touched.
// Keychain prompts are disabled, so a locked or unavailable keychain fails instead of asking.

import Foundation
import Security

struct Failure: Error { let what: String }

@main struct PairingKeyChecks {
    static func check(_ ok: Bool, _ what: String) throws {
        if !ok { throw Failure(what: what) }
    }

    static func run() throws {
        var interaction = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&interaction)
        SecKeychainSetUserInteractionAllowed(false)
        PairingKey.service = "uc-steer-test-\(UUID().uuidString)"
        defer {
            _ = PairingKey.save(nil)
            SecKeychainSetUserInteractionAllowed(interaction.boolValue)
        }

        try check(PairingKey.read() == nil, "starts empty")
        try check(PairingKey.save(nil) == errSecSuccess, "clearing a missing item succeeds")
        try check(PairingKey.save("AAAA") == errSecSuccess && PairingKey.read() == "AAAA", "add when missing")
        try check(PairingKey.save("BBBB") == errSecSuccess && PairingKey.read() == "BBBB", "update existing")
        try check(PairingKey.save(nil) == errSecSuccess && PairingKey.read() == nil, "clear removes it")
    }

    static func main() {
        do { try run(); print("ok") } catch let e as Failure { print("FAIL: \(e.what)"); exit(1) } catch { exit(1) }
    }
}
