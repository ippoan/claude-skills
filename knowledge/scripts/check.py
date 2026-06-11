#!/usr/bin/env python3
"""knowledge エントリの規約リンター (Python stdlib のみ / PyYAML 非依存)。

規約定義は knowledge/rules.json が単一の真実。本スクリプトはそれを読み、
decisions/ standards/ のエントリと (--skills 指定時) リポジトリ全体のスキルを
点検する。frontmatter は flat な `key: value` のみを想定し自前パースする。

exit code: error が 1 件以上で 1 (CI fail)、warn のみ / クリーンは 0。

使い方:
    python3 knowledge/scripts/check.py            # knowledge エントリを点検 (blocking)
    python3 knowledge/scripts/check.py --skills    # 上記 + SKILL.md lint (warn のみ)
    python3 knowledge/scripts/check.py --root DIR --rules PATH   # テスト用
"""
import argparse
import json
import os
import re
import sys
from datetime import datetime, date

FENCE = "---"


class Finding:
    __slots__ = ("level", "path", "rule", "msg")

    def __init__(self, level, path, rule, msg):
        self.level = level
        self.path = path
        self.rule = rule
        self.msg = msg


# ---------------------------------------------------------------- parsing


def parse_frontmatter(text):
    """先頭の `---` ブロックを flat key:value としてパースする。

    returns (fm: dict|None, flat_ok: bool, has_block: bool)
    flat_ok=False は「ネスト / 複数行値 / key:value でない行」があったことを示す。
    """
    lines = text.split("\n")
    if not lines or lines[0].strip() != FENCE:
        return None, True, False
    i = 1
    raw = []
    while i < len(lines) and lines[i].strip() != FENCE:
        raw.append(lines[i])
        i += 1
    if i >= len(lines):  # 閉じ --- が無い
        return None, True, False
    fm = {}
    flat_ok = True
    for ln in raw:
        if ln.strip() == "" or ln.lstrip().startswith("#"):
            continue
        if ln[0] in (" ", "\t"):  # インデント = ネスト
            flat_ok = False
            continue
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s?(.*)$", ln)
        if not m:  # key: value でない行 = 複数行値の継続等
            flat_ok = False
            continue
        fm[m.group(1)] = m.group(2).rstrip()
    return fm, flat_ok, True


def parse_list(val):
    v = (val or "").strip()
    if v.startswith("[") and v.endswith("]"):
        v = v[1:-1].strip()
    if not v:
        return []
    return [t.strip() for t in v.split(",") if t.strip()]


def first_section(text):
    """frontmatter の後の最初の `## ` 見出しを返す (無ければ None)。"""
    lines = text.split("\n")
    i = 0
    if lines and lines[0].strip() == FENCE:
        i = 1
        while i < len(lines) and lines[i].strip() != FENCE:
            i += 1
        i += 1  # 閉じ --- の次へ
    for ln in lines[i:]:
        if ln.startswith("## "):
            return ln.strip()
    return None


def md_files(d):
    out = []
    if not os.path.isdir(d):
        return out
    for root, _dirs, files in os.walk(d):
        for f in files:
            if f.endswith(".md"):
                out.append(os.path.join(root, f))
    return sorted(out)


# ---------------------------------------------------------------- common


def check_common(rel, text, fm, cfg, out):
    n = len(text.split("\n"))
    if n > cfg.get("max_lines", 300):
        out.append(Finding("warn", rel, "common.max_lines",
                           f"{n} 行 (>{cfg['max_lines']}) — 分割を検討"))
    if fm and "date" in fm:
        v = fm["date"].strip()
        try:
            d = datetime.strptime(v, "%Y-%m-%d").date()
            if d > date.today():
                out.append(Finding("warn", rel, "common.future_date",
                                   f"未来日付 {v}"))
        except ValueError:
            out.append(Finding("warn", rel, "common.non_iso_date",
                               f"非 ISO 日付 {v!r} (YYYY-MM-DD で書く)"))
    if fm and "tags" in fm:
        tags = parse_list(fm["tags"])
        if not tags:
            out.append(Finding("warn", rel, "common.empty_tags", "tags が空"))
        for t in tags:
            if t != t.lower() or " " in t:
                out.append(Finding("warn", rel, "common.tag_style",
                                   f"tag 表記ゆれ: {t!r} (lower-kebab 推奨)"))


# ---------------------------------------------------------------- decisions


def check_decisions(root, rules, out):
    cfg = rules["decisions"]
    common = rules["common"]
    dec_dir = os.path.join(root, cfg["dir"])
    arc_dir = os.path.join(root, cfg["archive_dir"])
    pat = re.compile(cfg["filename_pattern"])
    files = [(f, False) for f in md_files(dec_dir)] + \
            [(f, True) for f in md_files(arc_dir)]
    for path, in_archive in files:
        rel = os.path.relpath(path, root)
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        fm, flat_ok, has_block = parse_frontmatter(text)

        if not pat.match(name):
            out.append(Finding("error", rel, "decisions.filename",
                               "YYYY-MM-DD-kebab-case.md にする"))
        if not has_block or fm is None:
            out.append(Finding("error", rel, "decisions.required_keys",
                               "frontmatter (--- ブロック) が無い"))
            continue
        if not flat_ok:
            out.append(Finding("error", rel, "decisions.flat_frontmatter",
                               "frontmatter は flat な key: value のみ"))
        missing = [k for k in cfg["required_frontmatter"] if k not in fm]
        if missing:
            out.append(Finding("error", rel, "decisions.required_keys",
                               f"必須キー欠落: {', '.join(missing)}"))
        status = fm.get("status", "").strip()
        if status and status not in cfg["status_vocab"]:
            out.append(Finding("error", rel, "decisions.status_vocab",
                               f"status={status!r} は {cfg['status_vocab']} のいずれか"))
        if status == "superseded":
            if not fm.get("superseded_by", "").strip():
                out.append(Finding("error", rel, "decisions.superseded_by",
                                   "status=superseded には superseded_by が必須"))
            if not in_archive:
                out.append(Finding("error", rel, "decisions.superseded_location",
                                   f"superseded は {cfg['archive_dir']}/ に移す"))
        sec = first_section(text)
        if sec != cfg["first_section"]:
            out.append(Finding("error", rel, "decisions.first_section_summary",
                               f"先頭セクションは {cfg['first_section']!r} (実際: {sec!r})"))
        check_common(rel, text, fm, common, out)


# ---------------------------------------------------------------- standards


def check_standards(root, rules, out):
    cfg = rules["standards"]
    common = rules["common"]
    std_dir = os.path.join(root, cfg["dir"])
    for path in md_files(std_dir):
        rel = os.path.relpath(path, root)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        fm, flat_ok, has_block = parse_frontmatter(text)
        if not has_block or fm is None:
            out.append(Finding("error", rel, "standards.required_keys",
                               "frontmatter (--- ブロック) が無い"))
            continue
        if not flat_ok:
            out.append(Finding("error", rel, "standards.flat_frontmatter",
                               "frontmatter は flat な key: value のみ"))
        missing = [k for k in cfg["required_frontmatter"] if k not in fm]
        if missing:
            out.append(Finding("error", rel, "standards.required_keys",
                               f"必須キー欠落: {', '.join(missing)}"))
        status = fm.get("status", "").strip()
        if status and status not in cfg["status_vocab"]:
            out.append(Finding("error", rel, "standards.status_vocab",
                               f"status={status!r} は {cfg['status_vocab']} のいずれか"))
        check_common(rel, text, fm, common, out)


# ---------------------------------------------------------------- skill lint


def check_skills(root, rules, out):
    cfg = rules.get("skill_lint")
    if not cfg:
        return
    readme_path = os.path.join(root, cfg.get("readme", "README.md"))
    readme = ""
    if os.path.isfile(readme_path):
        with open(readme_path, encoding="utf-8") as fh:
            readme = fh.read()
    found = {sys_name: [] for sys_name in cfg["placement_systems"]}
    for base in cfg["skill_dirs"]:
        base_dir = os.path.join(root, base)
        if not os.path.isdir(base_dir):
            continue
        system = ".claude/skills" if base.endswith(".claude/skills") else "repo-root"
        for entry in sorted(os.listdir(base_dir)):
            skill_md = os.path.join(base_dir, entry, "SKILL.md")
            if not os.path.isfile(skill_md):
                continue
            found.setdefault(system, []).append(entry)
            rel = os.path.relpath(skill_md, root)
            with open(skill_md, encoding="utf-8") as fh:
                text = fh.read()
            fm, _flat, has_block = parse_frontmatter(text)
            if not has_block or not fm or not fm.get("description", "").strip():
                # description が複数行 ('>' block) の場合 flat parse では拾えないので
                # 生テキストにも当てる
                if "description:" not in text:
                    out.append(Finding("warn", rel, "skill.description_present",
                                       "frontmatter に description が無い"))
            if readme and entry not in readme:
                out.append(Finding("warn", rel, "skill.readme_listed",
                                   f"README 一覧に '{entry}' が未掲載"))
    sizes = {k: len(v) for k, v in found.items()}
    if all(sizes.get(s, 0) > 0 for s in cfg["placement_systems"]):
        out.append(Finding("warn", "(repo)", "skill.placement_split",
                           f"置き場 2 系統: {sizes} (統一方針は未確定)"))


# ---------------------------------------------------------------- driver


def run_checks(root, rules, do_skills=False):
    out = []
    check_decisions(root, rules, out)
    check_standards(root, rules, out)
    if do_skills:
        check_skills(root, rules, out)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    default_root = os.path.dirname(os.path.dirname(here))  # repo root (parent of knowledge/)
    ap.add_argument("--root", default=default_root)
    ap.add_argument("--rules", default=os.path.join(here, "..", "rules.json"))
    ap.add_argument("--skills", action="store_true",
                    help="SKILL.md lint (warn のみ) も走らせる")
    args = ap.parse_args(argv)

    with open(args.rules, encoding="utf-8") as fh:
        rules = json.load(fh)
    findings = run_checks(args.root, rules, do_skills=args.skills)

    errors = [f for f in findings if f.level == "error"]
    warns = [f for f in findings if f.level == "warn"]
    for f in findings:
        tag = "ERROR" if f.level == "error" else "warn "
        print(f"{tag} {f.path}: [{f.rule}] {f.msg}")
    print(f"\n{len(errors)} error(s), {len(warns)} warning(s)")
    if errors:
        print("knowledge 規約違反 (error) があります。修正してください。")
        return 1
    print("OK (error 0)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
