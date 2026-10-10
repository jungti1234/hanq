#!/bin/bash
# Run outside the restricted AppKit sandbox. No global taps or actual key posts.
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d "$PWD/.build/hanq/onset.XXXXXX")
trap 'rm -rf "$stage"' EXIT
swiftc Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/main.swift -o "$stage/tests"
for mode in editor-transitions layouts ack-timeout shift-onset early-capture early-publication restart recovery selection-retry selected-replacement superseded selection-read auto-resume prefix-delay drain rollback field-tracking; do
    "$stage/tests" "--test-$mode"
done
"$stage/tests" --test-integration --diagnose-input "$stage/privacy.log"
if rg -q 'PRIVATE_ONSET_PAYLOAD|"code"|"events"' "$stage/privacy.log"; then exit 1; fi
rg -q 'onset.privacy_check' "$stage/privacy.log"
echo 'PASS: production onset diagnostics omit text, clipboard and key payloads'
# Run focused detector, gate and deletion-event checks against product implementations.
for group in detector gate delete; do
    case "$group" in
        detector) fixture=Tests/OnsetRecovery/Detector/main.swift; sources=(Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/OnsetRecoveryPlan.swift Sources/HanQ/OnsetRecoveryDetector.swift Sources/HanQ/OnsetKeyboardLayout.swift Sources/HanQ/KoreanKeyboardLayout.swift) ;;
        gate) fixture=Tests/OnsetRecovery/Gate/main.swift; sources=(Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/OnsetInputGate.swift Sources/HanQ/OnsetSafetyDiagnostics.swift) ;;
        delete) fixture=Tests/OnsetRecovery/DeleteKey/main.swift; sources=(Sources/HanQ/OnsetDeletionKey.swift) ;;
    esac
    swiftc -module-cache-path .build/hanq/module-cache "${sources[@]}" "$fixture" -o "$stage/$group"
    "$stage/$group"
done

# Initial AX failure, grace period, safe resumption and old-event isolation.
swiftc Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/EarlyReadFailure/main.swift -o "$stage/early-read-failure"
"$stage/early-read-failure"

# Delayed first publication without extending the input hold.
swiftc Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/DeferredRead/main.swift -o "$stage/deferred-read"
"$stage/deferred-read"

# Unverified first fields must not retain physical input.
swiftc Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/UnclaimedInput/main.swift -o "$stage/unclaimed-input"
"$stage/unclaimed-input"

# Opt-in safety diagnostics expose counts and fixed reasons, never input payloads.
swiftc Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/SafetyDiagnostics/main.swift -o "$stage/safety-diagnostics"
"$stage/safety-diagnostics"
"$stage/safety-diagnostics" --diagnose-input "$stage/safety.log"

# Continuous progress and missing acknowledgments use individual post deadlines.
swiftc Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/AcknowledgmentProgress/main.swift -o "$stage/ack-progress"
"$stage/ack-progress"

# Distinguish transient reads from actual target/source changes without changing delivery.
swiftc Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/DeliveryContext/main.swift -o "$stage/delivery-context"
"$stage/delivery-context"
"$stage/delivery-context" --diagnose-input "$stage/delivery-context.log"
for reason in text_unreadable selection_invalid target_not_frontmost; do rg -q "readFailure=$reason" "$stage/delivery-context.log"; done
rg -q 'snapshot=true planField=true sameField=false sameSource=unchecked' "$stage/delivery-context.log"
rg -q 'snapshot=true planField=true sameField=true sameSource=false' "$stage/delivery-context.log"

# A temporary content read failure preserves the active bounded replay transaction.
swiftc Sources/HanQ/JamoComposer.swift -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Tests/OnsetRecovery/ReplayReadWait/main.swift -o "$stage/replay-read-wait"
"$stage/replay-read-wait"

# Bounded history of already delivered keys may repair only an exact split sequence.
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/LateSequence/main.swift -o "$stage/late-sequence"
"$stage/late-sequence"

# A completed replay must not poison later unedited observations after a pause.
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/ResumeReplayState/main.swift -o "$stage/resume-replay-state"
"$stage/resume-replay-state"

# Completed late words use one target-bound edit, never focus-routed key bursts.
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/CommittedReplacement/main.swift -o "$stage/committed-replacement"
"$stage/committed-replacement"

# Fixed decision traces never change routing or retain key/text payloads.
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/ReentryDiagnostics/main.swift -o "$stage/reentry-diagnostics"
"$stage/reentry-diagnostics"
"$stage/reentry-diagnostics" --diagnose-input "$stage/reentry.log"

# A known field anchors passed input without requiring a sampled outside state.
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/UnobservedReentry/main.swift -o "$stage/unobserved-reentry"
"$stage/unobserved-reentry"

# Paused original-target baselines and superseded unedited reservations remain observable.
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/PausedPassedBaseline/main.swift -o "$stage/paused-passed-baseline"
"$stage/paused-passed-baseline"

# Closing confirmed empty delivery never requires the old current focus.
swiftc -module-cache-path .build/hanq/module-cache Sources/HanQ/InputFocusAccess.swift Sources/HanQ/InputSourceAccess.swift Sources/HanQ/PhysicalLetterKeys.swift Sources/HanQ/Onset*.swift Sources/HanQ/InputDiagnostics.swift Sources/HanQ/KoreanKeyboardLayout.swift Sources/HanQ/JamoComposer.swift Tests/OnsetRecovery/QuietCompletion/main.swift -o "$stage/quiet-completion"
"$stage/quiet-completion"
