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

        try check(try PairingKey.read() == nil, "starts empty")
        try check(PairingKey.save(nil) == errSecSuccess, "clearing a missing item succeeds")
        try check(PairingKey.save("AAAA") == errSecSuccess && (try PairingKey.read()) == "AAAA", "add when missing")
        try check(PairingKey.save("BBBB") == errSecSuccess && (try PairingKey.read()) == "BBBB", "update existing")
        try check(PairingKey.save(nil) == errSecSuccess && (try PairingKey.read()) == nil, "clear removes it")

        try check(try PairingKey.decode(errSecItemNotFound, nil) == nil, "missing item is nil")
        try check(try PairingKey.decode(errSecSuccess, Data("KEY".utf8) as CFData) == "KEY", "valid data decodes")
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable] {
            do { _ = try PairingKey.decode(status, nil); throw Failure(what: "status \(status) must throw") }
            catch PairingKey.ReadError.keychain(let got) { try check(got == status, "status \(status) preserved") }
        }
        for bad: CFTypeRef? in [nil, Data([0xFF, 0xFE]) as CFData] {
            do { _ = try PairingKey.decode(errSecSuccess, bad); throw Failure(what: "invalid data must throw") }
            catch PairingKey.ReadError.invalidData {}
        }
    }

    static func main() {
        do { try run(); print("ok") } catch let e as Failure { print("FAIL: \(e.what)"); exit(1) } catch { exit(1) }
    }
}
