import Foundation
import CryptoKit

@main struct Fixtures {
    static func main() throws {
        let app = URL(fileURLWithPath: CommandLine.arguments[1])
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let info: [String: Any] = ["CFBundleIdentifier": "taek.in.hanq.update-tests", "CFBundleName": "HanQ Update Tests",
            "CFBundleExecutable": "HanQUpdateTests", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "0.1.0", "HanQReleaseVersion": "0.1.0-beta.1",
            "SUFeedURL": "https://jungti1234.github.io/hanq/appcast.xml", "SUPublicEDKey": publicKey,
            "HanQPolicyURL": "https://jungti1234.github.io/hanq/policy.json", "HanQPolicyPublicKey": publicKey,
            "SUEnableAutomaticChecks": false, "SUEnableSystemProfiling": false, "SUAllowsAutomaticUpdates": false,
            "CFBundleAllowMixedLocalizations": true, "NSPrincipalClass": "NSApplication"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let now = Date()
        let rule = UpdatePolicy.Rule(channel: "beta", architecture: "arm64", minimumOS: "13.0", maximumOS: nil,
            minimumBuild: 2, effectiveAt: now.addingTimeInterval(-60), reason: "보안 업데이트 동작을 확인하는 별도 테스트입니다.",
            targetBuild: 2, targetVersion: "0.1.0-beta.2",
            downloadURL: URL(string: "https://github.com/jungti1234/hanq/releases/download/test/HanQ.dmg")!)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for (name, rules) in [("required", [rule]), ("withdrawn", [])] {
            let policy = UpdatePolicy(schemaVersion: 1, bundleIdentifier: "taek.in.hanq", issuedAt: now.addingTimeInterval(-60),
                                      expiresAt: now.addingTimeInterval(3600), rules: rules)
            let data = try encoder.encode(policy)
            let signed = SignedUpdatePolicy(payload: data.base64EncodedString(), signature: try key.signature(for: data).base64EncodedString())
            try encoder.encode(signed).write(to: app.appendingPathComponent("Contents/Resources/\(name).json"))
        }
    }
}
