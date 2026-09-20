import Foundation
import CryptoKit

@main struct TestKey {
    static func main() throws {
        let key = Curve25519.Signing.PrivateKey()
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        // Disposable test seed, unrelated to either production Keychain key.
        FileManager.default.createFile(atPath: url.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                       attributes: [.posixPermissions: 0o600])
        print(key.publicKey.rawRepresentation.base64EncodedString())
    }
}
