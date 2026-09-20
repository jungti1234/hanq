//
//  RomanSwitchController.swift
//
//  Controls macOS's Roman Switch setting used by:
//  "Use the Caps Lock key to switch to and from [Latin input source]"
//  ("한/A 키로 ABC 입력 소스 전환")
//
//  IMPORTANT:
//  This implementation uses undocumented private HIToolbox symbols.
//  These symbols may change or disappear in future macOS versions.
//

import Foundation
import Darwin

enum RomanSwitchController {

    enum Error: Swift.Error, LocalizedError {
        case frameworkUnavailable(String?)
        case symbolUnavailable(String)
        case verificationFailed(expected: Bool, actual: Bool)

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable(let detail):
                if let detail, !detail.isEmpty {
                    return "Unable to load HIToolbox: \(detail)"
                }
                return "Unable to load HIToolbox."

            case .symbolUnavailable(let symbol):
                return "Required HIToolbox symbol is unavailable: \(symbol)"

            case .verificationFailed(let expected, let actual):
                return "Failed to change Roman Switch state. Expected \(expected), but actual state is \(actual)."
            }
        }
    }

    private typealias IsEnabledFunction = @convention(c) () -> Int32
    private typealias SetStateFunction = @convention(c) (Int32) -> Void

    private static let frameworkPath =
        "/System/Library/Frameworks/Carbon.framework/Versions/A/" +
        "Frameworks/HIToolbox.framework/Versions/A/HIToolbox"

    private static let isEnabledSymbolName = "TISIsRomanSwitchEnabled"
    private static let setStateSymbolName = "TISSetRomanSwitchState"

    // Values verified against the macOS System Settings toggle.
    private static let disabledState: Int32 = 0
    private static let enabledState: Int32 = 1

    private final class Runtime: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer
        let isEnabled: IsEnabledFunction
        let setState: SetStateFunction

        init() throws {
            guard let handle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) }
                throw Error.frameworkUnavailable(detail)
            }

            self.handle = handle

            do {
                guard let isEnabledSymbol = dlsym(handle, isEnabledSymbolName) else {
                    throw Error.symbolUnavailable(isEnabledSymbolName)
                }

                guard let setStateSymbol = dlsym(handle, setStateSymbolName) else {
                    throw Error.symbolUnavailable(setStateSymbolName)
                }

                self.isEnabled = unsafeBitCast(
                    isEnabledSymbol,
                    to: IsEnabledFunction.self
                )

                self.setState = unsafeBitCast(
                    setStateSymbol,
                    to: SetStateFunction.self
                )
            } catch {
                dlclose(handle)
                throw error
            }
        }

        deinit {
            dlclose(handle)
        }
    }

    private static let runtimeResult: Result<Runtime, Swift.Error> = {
        do {
            return .success(try Runtime())
        } catch {
            return .failure(error)
        }
    }()

    private static func runtime() throws -> Runtime {
        try runtimeResult.get()
    }

    /// Whether the required private HIToolbox symbols are available.
    static var isSupported: Bool {
        if case .success = runtimeResult {
            return true
        }
        return false
    }

    /// Returns the effective Roman Switch state as evaluated by HIToolbox.
    static func isEnabled() throws -> Bool {
        let runtime = try runtime()
        return runtime.isEnabled() != 0
    }

    /// Enables or disables Roman Switch and verifies the effective state.
    static func setEnabled(_ enabled: Bool) throws {
        let runtime = try runtime()

        runtime.setState(enabled ? enabledState : disabledState)

        let actual = runtime.isEnabled() != 0
        guard actual == enabled else {
            throw Error.verificationFailed(expected: enabled, actual: actual)
        }
    }
}
