import Foundation

// Only fixed stage/reason names and counts may enter onset safety traces.
// Never evaluate the generic engine log payload to produce these records.
enum OnsetSafetyDiagnostics {
    enum Stage:String { case stop, pause, resume, parked, sessionEnd, ackWait, ackReady, posted, started }
    static let reasons:Set<String> = [
        "none", "observation_stale", "hold_deadline", "gate_lock_timeout", "tap_disabled",
        "pointer_during_repair", "shortcut_during_repair", "buffer_limit", "permission_revoked",
        "tap_create_failed", "acknowledgment_gate_unavailable", "replay_acknowledgment_timeout",
        "repair_context_lost", "early_field_unavailable", "early_source_changed", "early_selection_changed",
        "early_field_changed", "early_context_changed", "early_claim_failed", "manual_edit_busy",
        "event_tap_disabled", "unsafe_delete_payload_blocked", "prefix_confirmation_context_lost",
        "prefix_not_visible", "prefix_post_rejected", "buffer_post_rejected", "rollback_context_not_intact",
        "rollback_delivery_context_changed", "rollback_unexpected_selection", "rollback_source_changed",
        "rollback_caret_rejected", "rollback_caret_timeout", "event_allocation_failed", "replay_target_changed"
    ]
    static let readFailures:Set<String> = [
        "accessibility_permission", "secure_input", "target_not_frontmost", "focused_element_unreadable",
        "secure_field", "role_unreadable", "not_supported_text_field", "active_composition",
        "text_unreadable", "selection_unreadable", "selection_invalid", "focus_changed_during_snapshot"
    ]
    static func readFailure(_ value:String)->String { value.isEmpty ? "none" : (readFailures.contains(value) ? value : "other") }
    static func reason(_ value:String)->String {reasons.contains(value) ? value:"other"}
}

// Bounded diagnostic records contain only fixed decisions, booleans and counts.
// Gate callbacks enqueue these values; file output occurs after releasing its lock.
enum OnsetReentryDiagnostics {
    enum Stage:String {case hint,key,history,claim,finish}
    enum Reason:String {
        case ready,not_outside,expiration_unacknowledged,stopped,hint_missing,hint_elapsed,reserved,not_eligible
        case unclaimed_followup,hold_active,history_expired,history_invalid,history_limit,history_release_invalid
        case observed_passed,baseline_missing
        case cancelled,guard_failed,field_changed,already_composed,detector_rejected,claim_accepted,claim_rejected,empty_finished
    }
    struct Frame {
        let sequence:Int;let inputSequence:Int;let decisionMonoNs:UInt64;let stage:Stage;let reason:Reason
        let hintMs:Int;let early:Bool;let expired:Bool;let holdMs:Int;let historyKeys:Int;let held:Int
        var line:String {"onset.reentry_gate seq=\(sequence) inputSeq=\(inputSequence) decisionMonoNs=\(decisionMonoNs) stage=\(stage.rawValue) reason=\(reason.rawValue) hintMs=\(hintMs) early=\(early) expired=\(expired) holdMs=\(holdMs) historyKeys=\(historyKeys) held=\(held)"}
    }
    static let engineReasons:Set<String>=["tracking","unsupported_layout","manual_busy","early_candidate","early_wait","early_skip","history_wait","history_complete","history_rejected","history_candidate","history_guard_failed","history_field_changed"]
    static func engineReason(_ value:String)->String {
        if engineReasons.contains(value){return value}
        return OnsetSafetyDiagnostics.readFailure(value)
    }
}
