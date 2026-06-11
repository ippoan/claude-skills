"""knowledge/scripts/check.py の unittest (Python stdlib のみ)。

一時ディレクトリに knowledge ツリーを組み、違反 fixture ごとに想定する
rule id が error / warn として出ることを検証する。
"""
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
KNOWLEDGE = os.path.dirname(HERE)
RULES = json.load(open(os.path.join(KNOWLEDGE, "rules.json"), encoding="utf-8"))

_spec = importlib.util.spec_from_file_location(
    "check", os.path.join(KNOWLEDGE, "scripts", "check.py"))
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)

VALID_DECISION = """---
title: テスト判断
date: 2026-06-11
status: active
tags: [ccow, test]
---

## Summary

一行。

## Context

x
"""

VALID_STANDARD = """---
title: テスト規範
category: libs
status: recommended
recommended: foo
---

結論。
"""


def write(root, rel, content):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(content)
    return p


def rules_of(findings, level=None):
    return [f.rule for f in findings if level is None or f.level == level]


class CheckTest(unittest.TestCase):
    def run_on(self, files):
        with tempfile.TemporaryDirectory() as root:
            for rel, content in files.items():
                write(root, rel, content)
            return check.run_checks(root, RULES)

    # ---- 正常系 -----------------------------------------------------
    def test_valid_clean(self):
        f = self.run_on({
            "knowledge/decisions/2026-06-11-ok.md": VALID_DECISION,
            "knowledge/standards/libs/x.md": VALID_STANDARD,
        })
        self.assertEqual([x for x in f if x.level == "error"], [])

    # ---- decisions error 系 ----------------------------------------
    def test_missing_required_keys(self):
        body = "---\ntitle: x\ndate: 2026-06-11\n---\n\n## Summary\n\ny\n"
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        self.assertIn("decisions.required_keys", rules_of(f, "error"))

    def test_bad_status(self):
        body = VALID_DECISION.replace("status: active", "status: bogus")
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        self.assertIn("decisions.status_vocab", rules_of(f, "error"))

    def test_superseded_without_by_and_misplaced(self):
        body = VALID_DECISION.replace("status: active", "status: superseded")
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        errs = rules_of(f, "error")
        self.assertIn("decisions.superseded_by", errs)
        self.assertIn("decisions.superseded_location", errs)

    def test_superseded_in_archive_ok(self):
        body = VALID_DECISION.replace(
            "status: active", "status: superseded\nsuperseded_by: 2026-06-12-new")
        f = self.run_on({"knowledge/archive/2026-06-11-x.md": body})
        errs = rules_of(f, "error")
        self.assertNotIn("decisions.superseded_by", errs)
        self.assertNotIn("decisions.superseded_location", errs)

    def test_bad_filename(self):
        f = self.run_on({"knowledge/decisions/not_a_date.md": VALID_DECISION})
        self.assertIn("decisions.filename", rules_of(f, "error"))

    def test_missing_summary_section(self):
        body = VALID_DECISION.replace("## Summary", "## Intro")
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        self.assertIn("decisions.first_section_summary", rules_of(f, "error"))

    def test_nested_frontmatter(self):
        body = ("---\ntitle: x\ndate: 2026-06-11\nstatus: active\n"
                "tags:\n  - a\n  - b\n---\n\n## Summary\n\ny\n")
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        self.assertIn("decisions.flat_frontmatter", rules_of(f, "error"))

    # ---- standards error 系 ----------------------------------------
    def test_standards_missing_keys(self):
        body = "---\ntitle: x\ncategory: libs\n---\n\nz\n"
        f = self.run_on({"knowledge/standards/libs/x.md": body})
        self.assertIn("standards.required_keys", rules_of(f, "error"))

    def test_standards_bad_status(self):
        body = VALID_STANDARD.replace("status: recommended", "status: nope")
        f = self.run_on({"knowledge/standards/libs/x.md": body})
        self.assertIn("standards.status_vocab", rules_of(f, "error"))

    # ---- warn 系 ----------------------------------------------------
    def test_over_300_lines_warn(self):
        body = VALID_DECISION + ("\nx" * 320)
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        self.assertIn("common.max_lines", rules_of(f, "warn"))
        self.assertEqual([x for x in f if x.level == "error"], [])

    def test_future_date_warn(self):
        body = VALID_DECISION.replace("date: 2026-06-11", "date: 2099-01-01")
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        self.assertIn("common.future_date", rules_of(f, "warn"))

    def test_non_iso_date_warn(self):
        body = VALID_DECISION.replace("date: 2026-06-11", "date: 2026/06/11")
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        self.assertIn("common.non_iso_date", rules_of(f, "warn"))

    def test_empty_tags_warn(self):
        body = VALID_DECISION.replace("tags: [ccow, test]", "tags: []")
        f = self.run_on({"knowledge/decisions/2026-06-11-x.md": body})
        self.assertIn("common.empty_tags", rules_of(f, "warn"))


if __name__ == "__main__":
    unittest.main()
