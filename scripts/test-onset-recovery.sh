#!/bin/bash
# Run outside the restricted AppKit sandbox. No global taps or actual key posts.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/test-workspace.sh
stage=$(hanq_test_stage onset)
trap 'rm -rf "$stage"' EXIT
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/main.swift -o "$stage/tests"
for mode in editor-transitions layouts ack-timeout shift-onset early-capture early-publication restart recovery selection-retry selected-replacement superseded selection-read auto-resume prefix-delay drain rollback field-tracking; do
    hanq_test_run "$stage/tests" "--test-$mode"
done
hanq_test_run "$stage/tests" --test-integration --diagnose-input "$stage/privacy.log"
hanq_test_run "$stage/tests" --test-integration --diagnose-input-incidents "$stage/incidents"
hanq_test_run "$stage/tests" --test-selection-retry --diagnose-input-incidents "$stage/incidents"
if rg -q 'PRIVATE_ONSET_PAYLOAD|"code"|"events"' "$stage/privacy.log"; then exit 1; fi
rg -q 'onset.privacy_check' "$stage/privacy.log"
echo 'PASS: production onset diagnostics omit text, clipboard and key payloads'
# Run focused detector, gate and deletion-event checks against product implementations.
for group in detector gate delete; do
    case "$group" in
        detector) fixture=Tests/OnsetRecovery/Detector/main.swift; sources=(Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/OnsetRecoveryPlan.swift Sources/HanQ/OnsetRecoveryDetector.swift Sources/HanQ/OnsetKeyboardLayout.swift Sources/HanQ/KoreanKeyboardLayout.swift) ;;
        gate) fixture=Tests/OnsetRecovery/Gate/main.swift; sources=(Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift) ;;
        delete) fixture=Tests/OnsetRecovery/DeleteKey/main.swift; sources=(Sources/HanQ/OnsetDeletionKey.swift) ;;
    esac
    swiftc -module-cache-path .build/hanq/module-cache "${sources[@]}" "$fixture" -o "$stage/$group"
    hanq_test_run "$stage/$group"
done

# Initial AX failure, grace period, safe resumption and old-event isolation.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/EarlyReadFailure/main.swift -o "$stage/early-read-failure"
hanq_test_run "$stage/early-read-failure"

# Delayed first publication without extending the input hold.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/DeferredRead/main.swift -o "$stage/deferred-read"
hanq_test_run "$stage/deferred-read"

# Unverified first fields must not retain physical input.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/UnclaimedInput/main.swift -o "$stage/unclaimed-input"
hanq_test_run "$stage/unclaimed-input"

# Opt-in safety diagnostics expose counts and fixed reasons, never input payloads.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/SafetyDiagnostics/main.swift -o "$stage/safety-diagnostics"
hanq_test_run "$stage/safety-diagnostics"
hanq_test_run "$stage/safety-diagnostics" --diagnose-input "$stage/safety.log"

# Continuous progress and missing acknowledgments use individual post deadlines.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/AcknowledgmentProgress/main.swift -o "$stage/ack-progress"
hanq_test_run "$stage/ack-progress"

# Distinguish transient reads from actual target/source changes without changing delivery.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/DeliveryContext/main.swift -o "$stage/delivery-context"
hanq_test_run "$stage/delivery-context"
hanq_test_run "$stage/delivery-context" --diagnose-input "$stage/delivery-context.log"
for reason in text_unreadable selection_invalid target_not_frontmost; do rg -q "readFailure=$reason" "$stage/delivery-context.log"; done
rg -q 'snapshot=true planField=true sameField=false sameSource=unchecked' "$stage/delivery-context.log"
rg -q 'snapshot=true planField=true sameField=true sameSource=false' "$stage/delivery-context.log"

# A temporary content read failure preserves the active bounded replay transaction.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/ReplayReadWait/main.swift -o "$stage/replay-read-wait"
hanq_test_run "$stage/replay-read-wait"

# Bounded history of already delivered keys may repair only an exact split sequence.
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/LateLayoutCases.swift Tests/OnsetRecovery/LateSequence/main.swift -o "$stage/late-sequence"
hanq_test_run "$stage/late-sequence"

# A completed replay must not poison later unedited observations after a pause.
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/ResumeReplayState/main.swift -o "$stage/resume-replay-state"
hanq_test_run "$stage/resume-replay-state"

# Completed late words use one target-bound edit, never focus-routed key bursts.
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/CommittedReplacement/main.swift -o "$stage/committed-replacement"
hanq_test_run "$stage/committed-replacement"

# Fixed decision traces never change routing or retain key/text payloads.
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/ReentryDiagnostics/main.swift -o "$stage/reentry-diagnostics"
hanq_test_run "$stage/reentry-diagnostics"
hanq_test_run "$stage/reentry-diagnostics" --diagnose-input "$stage/reentry.log"

# A known field anchors passed input without requiring a sampled outside state.
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/UnobservedReentry/main.swift -o "$stage/unobserved-reentry"
hanq_test_run "$stage/unobserved-reentry"

# Paused original-target baselines and superseded unedited reservations remain observable.
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/PausedPassedBaseline/main.swift -o "$stage/paused-passed-baseline"
hanq_test_run "$stage/paused-passed-baseline"

# Closing confirmed empty delivery never requires the old current focus.
swiftc Sources/HanQ/KeyboardStateMirror.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/QuietCompletion/main.swift -o "$stage/quiet-completion"
hanq_test_run "$stage/quiet-completion"

# Native composition must commit through the editor before selecting its onset.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/CompositionCommit/main.swift -o "$stage/composition-commit"
hanq_test_run "$stage/composition-commit"

# Retry AX activation after persistent focus loss, outside keyboard/edit paths.
bash scripts/test-onset-accessibility-activation.sh

# First-key focus without a pre-key field must never quarantine the following vowel.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/UnanchoredOnset/main.swift -o "$stage/unanchored-onset"
hanq_test_run "$stage/unanchored-onset"

# A committed Space may overlap its release with the next word; never replay a fabricated Space down.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/SpaceRollover/main.swift -o "$stage/space-rollover"
hanq_test_run "$stage/space-rollover"

# An ignored committed edit must await asynchronous caret cleanup before releasing originals.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/CommittedCaretRestoration/main.swift -o "$stage/committed-caret-restoration"
hanq_test_run "$stage/committed-caret-restoration"

# First-input focus handoff never edits text or retains/replays the original key.
swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/FocusHandoff/main.swift -o "$stage/focus-handoff"
hanq_test_run "$stage/focus-handoff"

swiftc Sources/HanQ/KeyboardStateMirror.swift Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/SyntheticInputMarker.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/FocusHandoffDiagnostics/main.swift -o "$stage/focus-handoff-diagnostics"
hanq_test_run "$stage/focus-handoff-diagnostics" --diagnose-input "$stage/focus-off.log"
hanq_test_run "$stage/focus-handoff-diagnostics" --trace-onset-focus --diagnose-input "$stage/focus-on.log"
