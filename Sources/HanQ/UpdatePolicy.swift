import Foundation
import CryptoKit

/// The envelope signs the exact payload bytes; JSON serialization is not part of verification.
struct SignedUpdatePolicy: Codable {
    let payload: String
    let signature: String
}

struct UpdatePolicy: Codable {
    let schemaVersion: Int
    let bundleIdentifier: String
    let issuedAt: Date
    let expiresAt: Date
    let rules: [Rule]

    struct Rule: Codable, Equatable {
        let channel: String
        let architecture: String
        let minimumOS: String
        let maximumOS: String?
        let minimumBuild: Int
        let effectiveAt: Date
        let reason: String
        let targetBuild: Int
        let targetVersion: String
        let downloadURL: URL
    }

    struct Context {
        let build: Int
        let channel: String
        let architecture: String
        let osVersion: String
    }

    enum Invalid: Error { case signature, document }

    static func decode(_ data: Data, publicKey: Data, now: Date) throws -> UpdatePolicy {
        guard data.count <= 128 * 1024 else { throw Invalid.document }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(SignedUpdatePolicy.self, from: data)
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload) else { throw Invalid.signature }
        let policy = try decoder.decode(UpdatePolicy.self, from: payload)
        guard policy.schemaVersion == 1, policy.bundleIdentifier == "taek.in.hanq",
              policy.issuedAt <= now, policy.expiresAt > now,
              policy.expiresAt > policy.issuedAt, policy.rules.count <= 32 else { throw Invalid.document }
        for rule in policy.rules {
            guard ["beta", "stable"].contains(rule.channel), rule.architecture == "arm64",
                  osParts(rule.minimumOS) != nil,
                  rule.maximumOS.map({ osParts($0) != nil && compareOS($0, rule.minimumOS) >= 0 }) ?? true,
                  rule.minimumBuild > 0, rule.targetBuild >= rule.minimumBuild,
                  !rule.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rule.reason.count <= 1000, !rule.targetVersion.isEmpty, rule.targetVersion.count <= 80,
                  trustedDownload(rule.downloadURL) else { throw Invalid.document }
        }
        return policy
    }

    func requiredUpdate(for context: Context, now: Date) -> Rule? {
        guard now >= issuedAt, now < expiresAt else { return nil }
        return rules.filter {
            $0.channel == context.channel && $0.architecture == context.architecture &&
            $0.effectiveAt <= now && context.build < $0.minimumBuild &&
            Self.compareOS(context.osVersion, $0.minimumOS) >= 0 &&
            ($0.maximumOS.map { Self.compareOS(context.osVersion, $0) <= 0 } ?? true)
        }.max { $0.minimumBuild < $1.minimumBuild }
    }

    static func trustedDownload(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil &&
        url.port == nil && url.query == nil && url.fragment == nil &&
        url.path.hasPrefix("/jungti1234/hanq/releases/download/") &&
        ["dmg", "zip"].contains(url.pathExtension.lowercased())
    }

    private static func osParts(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let numbers = parts.map { Int($0)! }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    private static func compareOS(_ lhs: String, _ rhs: String) -> Int {
        guard let a = osParts(lhs), let b = osParts(rhs) else { return -1 }
        for (x, y) in zip(a, b) where x != y { return x < y ? -1 : 1 }
        return 0
    }
}
