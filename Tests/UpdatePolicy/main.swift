import Foundation
import CryptoKit

let now = Date(timeIntervalSince1970: 1_800_000_000)
let key = Curve25519.Signing.PrivateKey()
let context = UpdatePolicy.Context(build: 72, channel: "beta", architecture: "arm64", osVersion: "15.7.9")
func document(minimum: Int = 85, target: Int = 85, channel: String = "beta", minimumOS: String = "13.0", maximumOS: String? = nil,
              effective: Date = now, expires: Date = now.addingTimeInterval(3600),
              url: String = "https://github.com/jungti1234/hanq/releases/download/v0.1.0-beta.2/HanQ.dmg") -> UpdatePolicy {
    .init(schemaVersion: 1, bundleIdentifier: "taek.in.hanq", issuedAt: now.addingTimeInterval(-60), expiresAt: expires,
          rules: [.init(channel: channel, architecture: "arm64", minimumOS: minimumOS, maximumOS: maximumOS,
                        minimumBuild: minimum, effectiveAt: effective, reason: "보안 수정", targetBuild: target,
                        targetVersion: "0.1.0-beta.2", downloadURL: URL(string: url)!)])
}
func envelope(_ policy: UpdatePolicy, signingKey: Curve25519.Signing.PrivateKey = key) throws -> Data {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let payload = try encoder.encode(policy)
    return try encoder.encode(SignedUpdatePolicy(payload: payload.base64EncodedString(),
                                                 signature: signingKey.signature(for: payload).base64EncodedString()))
}
func decode(_ policy: UpdatePolicy) throws -> UpdatePolicy {
    try UpdatePolicy.decode(envelope(policy), publicKey: key.publicKey.rawRepresentation, now: now)
}
var count = 0
func check(_ condition: Bool) { precondition(condition); count += 1 }
func rejects(_ data: Data) {
    do { _ = try UpdatePolicy.decode(data, publicKey: key.publicKey.rawRepresentation, now: now); fatalError("accepted invalid policy") }
    catch { count += 1 }
}
let valid = try decode(document())
check(valid.requiredUpdate(for: context, now: now) != nil)
check(try decode(document(minimum: 72)).requiredUpdate(for: context, now: now) == nil)
check(try decode(document(minimum: 71)).requiredUpdate(for: context, now: now) == nil)
check(try decode(document(channel: "stable")).requiredUpdate(for: context, now: now) == nil)
check(try decode(document(minimumOS: "26.0")).requiredUpdate(for: context, now: now) == nil)
check(try decode(document(maximumOS: "14.9")).requiredUpdate(for: context, now: now) == nil)
check(try decode(document(effective: now.addingTimeInterval(60))).requiredUpdate(for: context, now: now) == nil)
check(valid.requiredUpdate(for: context, now: now.addingTimeInterval(3600)) == nil)
check(valid.requiredUpdate(for: .init(build: 72, channel: "beta", architecture: "x86_64", osVersion: "15.7"), now: now) == nil)
rejects(try envelope(document(expires: now)))
rejects(try envelope(document(target: 84)))
rejects(try envelope(document(minimumOS: "bad")))
rejects(try envelope(document(maximumOS: "12.0")))
rejects(try envelope(document(url: "https://example.com/HanQ.dmg")))
rejects(try envelope(document(), signingKey: Curve25519.Signing.PrivateKey()))
rejects(Data(repeating: 0, count: 128 * 1024 + 1))
rejects(Data("{}".utf8))
let encoder = JSONEncoder()
let signed = try JSONDecoder().decode(SignedUpdatePolicy.self, from: envelope(document()))
rejects(try encoder.encode(SignedUpdatePolicy(payload: Data("tampered".utf8).base64EncodedString(), signature: signed.signature)))
let withdrawal = UpdatePolicy(schemaVersion: 1, bundleIdentifier: "taek.in.hanq", issuedAt: now, expiresAt: now.addingTimeInterval(60), rules: [])
check(try decode(withdrawal).requiredUpdate(for: context, now: now) == nil)
print("PASS: \(count) signed policy boundary, scope, expiry, tampering and withdrawal checks")

// Exercise the real asynchronous coordinator with deterministic network replies.
let liveNow = Date()
let live = UpdatePolicy(schemaVersion: 1, bundleIdentifier: "taek.in.hanq", issuedAt: liveNow.addingTimeInterval(-5),
                        expiresAt: liveNow.addingTimeInterval(3600), rules: document().rules)
var callbacks: [(Data?) -> Void] = []
var methods: [Bool] = []
var restrictions: [Bool] = []
var finished = 0
let client = UpdatePolicyClient(url: URL(string: "https://jungti1234.github.io/hanq/policy.json")!,
                               key: key.publicKey.rawRepresentation, context: context) { _, head, reply in
    methods.append(head); callbacks.append(reply); return nil
}
client.onChange = { restrictions.append($0 != nil) }
// liveNow can precede the fixed unit-test fixture's effective date.
let liveRule = UpdatePolicy.Rule(channel: "beta", architecture: "arm64", minimumOS: "13.0", maximumOS: nil,
    minimumBuild: 85, effectiveAt: liveNow.addingTimeInterval(-5), reason: "보안 수정", targetBuild: 85,
    targetVersion: "0.1.0-beta.2", downloadURL: document().rules[0].downloadURL)
let livePolicy = UpdatePolicy(schemaVersion: 1, bundleIdentifier: "taek.in.hanq", issuedAt: live.issuedAt,
                             expiresAt: live.expiresAt, rules: [liveRule])
client.check { finished += 1 }
client.check()
check(callbacks.count == 1 && client.isChecking)
callbacks.removeFirst()(try envelope(livePolicy))
check(methods == [false, true] && restrictions.isEmpty)
callbacks.removeFirst()(Data())
check(restrictions == [true] && !client.isChecking && finished == 1)
client.check()
callbacks.removeFirst()(nil)
check(restrictions == [true, false]) // Offline recheck releases an existing restriction.
client.check()
callbacks.removeFirst()(try envelope(livePolicy))
callbacks.removeFirst()(nil)
check(restrictions.last == false) // Unavailable installation file never restricts.
client.check()
let stale = callbacks.removeFirst()
client.stop()
stale(try envelope(livePolicy))
check(!client.isChecking && callbacks.isEmpty)
client.check()
let revoke = UpdatePolicy(schemaVersion: 1, bundleIdentifier: "taek.in.hanq", issuedAt: live.issuedAt,
                          expiresAt: live.expiresAt, rules: [])
callbacks.removeFirst()(try envelope(revoke))
check(restrictions.last == false)
client.stop()
print("PASS: policy coordinator coalescing, availability, offline recovery, cancellation and withdrawal (\(count) total)")
