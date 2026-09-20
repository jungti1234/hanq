import Foundation
import CryptoKit

@main struct TestKey {
    static func main() throws {
        let key = Curve25519.Signing.PrivateKey()
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        // Disposable test seed, unrelated to either production Keychain key.
        FileManager.default.createFile(atPath: url.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                       attributes: [.posixPermissions: 0o600])
        if CommandLine.arguments.count > 2 {
            let now = Date()
            let rule = UpdatePolicy.Rule(channel: "beta", architecture: "arm64", minimumOS: "13.0", maximumOS: nil,
                minimumBuild: 2, effectiveAt: now.addingTimeInterval(-60), reason: "별도 앱의 필수 업데이트 설치 검증입니다.",
                targetBuild: 2, targetVersion: "0.1.0-beta.2",
                downloadURL: URL(string: "https://github.com/jungti1234/hanq/releases/download/test/HanQ.dmg")!)
            let policy = UpdatePolicy(schemaVersion: 1, bundleIdentifier: "taek.in.hanq",
                issuedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(3600), rules: [rule])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(policy)
            let signed = SignedUpdatePolicy(payload: payload.base64EncodedString(),
                signature: try key.signature(for: payload).base64EncodedString())
            try encoder.encode(signed).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print(key.publicKey.rawRepresentation.base64EncodedString())
    }
}
