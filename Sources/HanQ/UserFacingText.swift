import Foundation

/// Shared wording and presentation-only formatting. Original NSError values
/// remain untouched so error domains, codes and underlying causes are retained.
enum UserFacingText {
    static let feedbackAction = "피드백 남기기…"
    static let storageProblemTitle = "진단 기록 저장에 문제가 있어요"
    static let storageProblemWindowTitle = "한Q - 진단 기록 저장 문제"
    static let manualStorageTitle = "문제 기록을 저장하지 못했어요"
    static let automaticUpdateExplanation = "한Q 메뉴에서 수동으로\n업데이트를 확인할 수도 있습니다."

    static func errorBody(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "권한이 없기 때문에 해당 파일을 저장할 수 없습니다.",
            with: "권한이 없기 때문에\n해당 파일을 저장할 수 없습니다.")
        let sentence = "작업을 완료할 수 없습니다."
        if let range = result.range(of: sentence), range.upperBound < result.endIndex {
            let suffix = result[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.hasPrefix("(") {
                result = String(result[..<range.upperBound]) + "\n" + suffix
            }
        }
        return result
    }

    static func heading(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, ".!。！".contains(last) { result.removeLast() }
        return result
    }

    static func updaterError(_ error: Error) -> NSError {
        let original = error as NSError
        var info = original.userInfo
        var body = errorBody(original.localizedDescription)
        if let suggestion = original.localizedRecoverySuggestion, !suggestion.isEmpty {
            body += "\n\n" + errorBody(suggestion)
        }
        info[NSLocalizedDescriptionKey] = "업데이트를 완료하지 못했어요"
        info[NSLocalizedRecoverySuggestionErrorKey] = body
        return NSError(domain: original.domain, code: original.code, userInfo: info)
    }

    static func updateNotFound(_ error: Error) -> NSError {
        let original = error as NSError
        var info = original.userInfo
        info[NSLocalizedDescriptionKey] = heading(original.localizedDescription)
        return NSError(domain: original.domain, code: original.code, userInfo: info)
    }
}
