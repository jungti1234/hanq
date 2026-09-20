import Foundation
import Darwin

enum FeedbackForm {
    static func url(bundle: Bundle = .main) -> URL? {
        let version = bundle.object(forInfoDictionaryKey: "HanQReleaseVersion") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "알 수 없음"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let appVersion = build.map { "\(version) (\($0))" } ?? version
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return makeURL(appVersion: appVersion,
                       macOSVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                       modelID: modelIdentifier())
    }

    static func makeURL(appVersion: String, macOSVersion: String, modelID: String?) -> URL? {
        var components = URLComponents(string: "https://docs.google.com/forms/d/e/1FAIpQLSd3EFa87qLHv1aYG0STEYZSD_RAjnAQAhTeQgSe3d-IEiNYyA/viewform")
        components?.queryItems = [
            URLQueryItem(name: "usp", value: "pp_url"),
            URLQueryItem(name: "entry.747699997", value: appVersion),
            URLQueryItem(name: "entry.1471588217", value: macOSVersion)
        ]
        if let modelID, !modelID.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "entry.485402029", value: modelID))
        }
        // Google Forms decodes '+' as a space in query values.
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    private static func modelIdentifier() -> String? {
        // Product model only; never read the serial number or hardware UUID.
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { sysctlbyname("hw.model", $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8)
    }
}
