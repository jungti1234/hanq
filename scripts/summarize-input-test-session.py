#!/usr/bin/env python3
"""Summarize human observations and opt-in HanQ metadata, without UI access."""
import argparse
import collections
import json
import importlib.util
from pathlib import Path


def summarize(folder):
    session = json.loads((folder / "session.json").read_text())
    events = [json.loads(path.read_text()) for path in sorted(folder.glob("event-*.json"))]
    captures = [json.loads(path.read_text()) for path in sorted((folder / "incidents").glob("incident-*.json"))]
    result = json.loads((folder / "result.json").read_text()) if (folder / "result.json").exists() else None
    kinds = collections.Counter(event["kind"] for event in events)
    summary = {
        "schema": 1,
        "target": session["target"],
        "recorder_self_test": session.get("selfTest", False),
        "finished": result is not None,
        "collection_complete": result.get("collectionComplete", False) if result else False,
        "observations": {"normal": kinds["observed_normal"], "loss": kinds["observed_loss"]},
        "manual_capture_requests_observed": kinds["hanq_manual_snapshot"],
        "hanq_exits_observed": kinds["product_exited"],
        "capture_files": len(captures),
        "capture_builds": sorted({capture["build"] for capture in captures}),
        "triggers": dict(collections.Counter(capture["trigger"] for capture in captures)),
        "capture_pairs_missing_phase": [incident for incident in sorted({c["incident"] for c in captures})
                                        if {c["phase"] for c in captures if c["incident"] == incident} != {0, 1}],
        "rejected_files": result.get("rejectedFiles", 0) if result else None,
        "chatgpt_receipt_verified": False,
        "interpretation": ("Recorder UI self-test only; these observations do not describe ChatGPT input."
                           if session.get("selfTest", False) else
                           "Human observations and HanQ metadata only; counts and no loss report do not prove editor delivery."),
    }
    status_paths=sorted(folder.glob("storage-*.json"))
    summary["storage_statuses"]=[]
    summary["rejected_storage_statuses"]=result.get("rejectedStorageStatuses",0) if result else None
    if status_paths:
        if len(status_paths)>16 or any(path.stat().st_size>16*1024 for path in status_paths):raise ValueError("storage status collection limit")
        spec=importlib.util.spec_from_file_location("incident_summary",Path(__file__).with_name("summarize-input-incident.py"))
        incident_summary=importlib.util.module_from_spec(spec);spec.loader.exec_module(incident_summary)
        summary["storage_statuses"]=[incident_summary.summarize_storage_document(json.loads(path.read_text())) for path in status_paths]
    if (folder / "auto-run.json").exists():
        plan = json.loads((folder / "auto-run.json").read_text())
        automatic = json.loads((folder / "auto-result.json").read_text()) if (folder / "auto-result.json").exists() else None
        target = json.loads((folder / "auto-target.json").read_text()) if (folder / "auto-target.json").exists() else {}
        cases = [json.loads(path.read_text()) for path in sorted(folder.glob("auto-case-*.json"))]
        matched = sum(case["bodyAndCaretMatched"] for case in cases)
        unpaced = sum(not case["pacingQualified"] for case in cases)
        planned = plan.get("casesPlanned")
        detailed_plan = plan.get("casePlan", [])
        known_plan = (planned == 30 and plan.get("schema", 1) == 1) or (
            planned == 100 and plan.get("schema") == 2
            and plan.get("planID") == "korean-composer-100-v1"
            and len(detailed_plan) == 100
            and [item.get("id") for item in detailed_plan] == list(range(1, 101)))
        expected = {item["id"]: item for item in detailed_plan}
        plan_mismatches = []
        for case in cases:
            item = expected.get(case["id"])
            if planned == 100 and (item is None or any(
                case.get(key) != item.get(key) for key in
                ("expectedSynthetic", "nominalGapMilliseconds", "overwrite"))
                or case.get("postedDowns") != item.get("expectedDowns")):
                plan_mismatches.append(case["id"])
        source_mismatches = [c["id"] for c in cases if not c.get("inputSourceMatched", planned == 30)]
        pair_mismatches = [c["id"] for c in cases if c.get("postedDowns") != c.get("postedUps")]
        differences = [c["id"] for c in cases if c.get("missingExpectedUTF16Indices") or c.get("unexpectedUTF16Units", 0)]
        final_counts_match = (planned == 30 or automatic is not None
                              and automatic.get("cases") == len(cases)
                              and automatic.get("bodyAndCaretMatches") == matched
                              and automatic.get("pacingUnqualified") == unpaced)
        complete = (automatic is not None and automatic.get("outcome") == "completed" and final_counts_match
                    and known_plan and len(cases) == planned
                    and sorted(case["id"] for case in cases) == list(range(1, planned + 1)))
        regression_passed = (complete and matched == planned and not source_mismatches
                             and not pair_mismatches and not differences and not plan_mismatches)
        genuine_scope = (not session.get("selfTest", False)
                         and target.get("bundle") == session["target"] == "com.openai.codex"
                         and all(case.get("scope") == "user-started-chatgpt" for case in cases))
        summary["automatic_test"] = {
            "outcome": automatic.get("outcome") if automatic else "unfinished",
            "planned": planned, "case_results": len(cases),
            "body_and_caret_matches": matched, "pacing_unqualified": unpaced,
            "full_suite_finished": complete,
            "nominal_speed_coverage_complete": complete and unpaced == 0,
            "input_regression_checks_passed": bool(regression_passed),
            "input_source_mismatch_cases": source_mismatches,
            "event_pair_mismatch_cases": pair_mismatches,
            "synthetic_difference_cases": differences,
            "plan_mismatch_cases": plan_mismatches,
            "coverage_by_nominal_gap_ms": dict(collections.Counter(str(c.get("nominalGapMilliseconds")) for c in cases)),
            "coverage_by_edit_mode": dict(collections.Counter(
                "initial_empty" if c["id"] == 1 else "selection_overwrite" if c.get("overwrite") else "clear_then_type"
                for c in cases)),
            "scope_limit": "Two-set Korean synthetic text, final body/caret/source, verified clear/overwrite and scheduling only. Language switching, Hanja, HUD and physical typing are not tested.",
            "verification_method": "AX body/caret after synthetic keys; separate from HanQ metadata",
        }
        summary["chatgpt_receipt_verified"] = bool(regression_passed and genuine_scope)
        summary["interpretation"] = "User-started automatic editor comparisons; full-suite, pacing and HanQ metadata are reported separately. No remote message submission is tested."
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.session), ensure_ascii=False, indent=2))
