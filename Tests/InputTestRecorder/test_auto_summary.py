import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("summary", Path(__file__).resolve().parents[2] / "scripts/summarize-input-test-session.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SummaryTests(unittest.TestCase):
    def test_hundred_case_integrity_and_regression_evidence(self):
        with tempfile.TemporaryDirectory(prefix="hanq-auto100-summary-") as name:
            root = Path(name)
            def write(file, data):
                (root / file).write_text(json.dumps(data))
            write("session.json", {"target": "com.openai.codex", "selfTest": False})
            write("auto-target.json", {"bundle": "com.openai.codex"})
            plan = [{"id": i, "expectedSynthetic": "고정 합성 문장", "expectedDowns": 20,
                     "nominalGapMilliseconds": [40, 20, 8][(i - 1) % 3], "overwrite": i % 2 == 0}
                    for i in range(1, 101)]
            run = {"schema": 2, "casesPlanned": 100, "planID": "korean-composer-100-v1", "casePlan": plan}
            write("auto-run.json", run)
            final = {"outcome": "completed", "cases": 100, "bodyAndCaretMatches": 100, "pacingUnqualified": 0}
            write("auto-result.json", final)
            rows = []
            for item in plan:
                row = {k: v for k, v in item.items() if k != "expectedDowns"}
                row.update(bodyAndCaretMatched=True, pacingQualified=True, inputSourceMatched=True,
                           postedDowns=20, postedUps=20, missingExpectedUTF16Indices=[],
                           unexpectedUTF16Units=0, scope="user-started-chatgpt")
                rows.append(row)
                write(f"auto-case-{item['id']:03}.json", row)
            result = module.summarize(root)
            self.assertTrue(result["chatgpt_receipt_verified"])
            self.assertTrue(result["automatic_test"]["input_regression_checks_passed"])
            self.assertEqual(result["automatic_test"]["coverage_by_edit_mode"],
                             {"initial_empty": 1, "selection_overwrite": 50, "clear_then_type": 49})
            for change in [{"id": 99}, {"postedUps": 19}, {"inputSourceMatched": False},
                           {"expectedSynthetic": "wrong plan"}, {"postedDowns": 19},
                           {"missingExpectedUTF16Indices": [1]}, {"unexpectedUTF16Units": 1},
                           {"scope": "owned-native-local-ime"}, {"bodyAndCaretMatched": False}]:
                with self.subTest(change=change):
                    write("auto-case-100.json", rows[-1] | change)
                    self.assertFalse(module.summarize(root)["chatgpt_receipt_verified"])
            write("auto-case-100.json", rows[-1] | {"pacingQualified": False})
            write("auto-result.json", final | {"pacingUnqualified": 1})
            result = module.summarize(root)
            self.assertTrue(result["chatgpt_receipt_verified"], "slow pacing is distinct from correct body")
            self.assertFalse(result["automatic_test"]["nominal_speed_coverage_complete"])
            write("auto-case-100.json", rows[-1])
            write("auto-result.json", final | {"cases": 30})
            self.assertFalse(module.summarize(root)["automatic_test"]["full_suite_finished"])
            write("auto-result.json", final)
            write("auto-run.json", run | {"casePlan": plan[:30]})
            self.assertFalse(module.summarize(root)["chatgpt_receipt_verified"])
            write("auto-run.json", run)
            for i in range(31, 101):
                (root / f"auto-case-{i:03}.json").unlink()
            self.assertFalse(module.summarize(root)["automatic_test"]["full_suite_finished"],
                             "a previous 30-case pass cannot satisfy a 100-case run")

    def test_automatic_scope_completion_and_pacing(self):
        with tempfile.TemporaryDirectory(prefix="hanq-auto-summary-") as name:
            root = Path(name)
            (root / "incidents").mkdir()
            def write(file, data):
                (root / file).write_text(json.dumps(data))
            write("session.json", {"target": "com.openai.codex", "selfTest": False})
            self.assertFalse(module.summarize(root)["chatgpt_receipt_verified"])
            write("auto-run.json", {"casesPlanned": 30})
            write("auto-target.json", {"bundle": "com.openai.codex"})
            for i in range(1, 31):
                write(f"auto-case-{i:03}.json", {"id": i, "bodyAndCaretMatched": True, "pacingQualified": True, "scope": "owned-native-local-ime"})
            write("auto-result.json", {"outcome": "completed"})
            self.assertFalse(module.summarize(root)["chatgpt_receipt_verified"], "owned native test is not ChatGPT")
            for i in range(1, 31):
                write(f"auto-case-{i:03}.json", {"id": i, "bodyAndCaretMatched": True, "pacingQualified": i != 1, "scope": "user-started-chatgpt"})
            result = module.summarize(root)
            self.assertTrue(result["chatgpt_receipt_verified"])
            self.assertFalse(result["automatic_test"]["nominal_speed_coverage_complete"])
            write("session.json", {"target": "com.openai.codex", "selfTest": True})
            self.assertFalse(module.summarize(root)["chatgpt_receipt_verified"], "UI self-test cannot verify ChatGPT")
            write("session.json", {"target": "com.openai.codex", "selfTest": False})
            write("auto-result.json", {"outcome": "textMismatch"})
            self.assertFalse(module.summarize(root)["chatgpt_receipt_verified"])
            write("auto-result.json", {"outcome": "ax_read_failure"})
            self.assertEqual(module.summarize(root)["automatic_test"]["outcome"], "ax_read_failure")
            (root / "auto-result.json").unlink()
            self.assertFalse(module.summarize(root)["automatic_test"]["full_suite_finished"])


if __name__ == "__main__":
    unittest.main()
