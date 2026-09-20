import Foundation
import CryptoKit
import Security

// Private material never leaves Keychain except in process memory for signing.
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "taek.in.hanq.update-policy", kSecAttrAccount as String: "ed25519"]
func signingKey(create: Bool) throws -> Curve25519.Signing.PrivateKey {
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
    guard create && status == errSecItemNotFound else {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    let key = Curve25519.Signing.PrivateKey()
    var item = query
    item[kSecValueData as String] = key.rawRepresentation
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    item[kSecAttrLabel as String] = "HanQ update policy signing key"
    let saved = SecItemAdd(item as CFDictionary, nil)
    guard saved == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(saved)) }
    return key
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first {
    case "init", "public-key":
        guard args.count == 1 else { throw UpdatePolicy.Invalid.document }
        print(try signingKey(create: args[0] == "init").publicKey.rawRepresentation.base64EncodedString())
    case "sign":
        guard args.count == 3 else { throw UpdatePolicy.Invalid.document }
        let key = try signingKey(create: false)
        let payload = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let envelope = SignedUpdatePolicy(payload: payload.base64EncodedString(),
                                          signature: try key.signature(for: payload).base64EncodedString())
        let data = try JSONEncoder().encode(envelope)
        _ = try UpdatePolicy.decode(data, publicKey: key.publicKey.rawRepresentation, now: Date())
        try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
        print("Signed policy: \(args[2])")
    case "verify":
        guard args.count == 3, let key = Data(base64Encoded: args[2]) else { throw UpdatePolicy.Invalid.document }
        _ = try UpdatePolicy.decode(Data(contentsOf: URL(fileURLWithPath: args[1])), publicKey: key, now: Date())
        print("Valid signed policy")
    default:
        fputs("Usage: policy-tool init | public-key | sign INPUT OUTPUT | verify FILE PUBLIC_KEY\n", stderr)
        exit(64)
    }
} catch {
    fputs("Policy operation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
