#!/usr/bin/env python3
"""`<repo>-map` の SKILL.md から人間向け MkDocs サイトを生成する。

Source of Truth は各 `<repo>-map/SKILL.md` (+ `.claude/skills/ippoan-infra-map`)。
このスクリプトは本文を `docs/` にコピーし、LLM 向けの frontmatter を剥がして
`generated-from` 由来の「対象 repo / 鮮度」バッジを先頭に差し込む。
`.github/workflows/pages.yml` が `mkdocs build` の前に実行する。
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
MAPS_OUT = DOCS / "maps"
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
DEFAULT_OWNER = "ippoan"
# owner 解決のホワイトリスト。本文中の `/home/user/...` パスや `anthropics/...`
# (upstream issue 引用) を owner と誤検出しないため、既知 org のみ採用する。
KNOWN_OWNERS = {"ippoan", "ohishi-exp", "yhonda-ohishi", "yhonda-ohishi-alc"}


# repo-map は「<repo>-map を作る手順」のメタ skill であって特定 repo の地図ではない。
EXCLUDE = {"repo-map"}


def map_sources() -> list[Path]:
    """top-level の `*-map/` + .claude/skills 配下の infra map を集める。"""
    srcs = [
        p
        for p in sorted(ROOT.glob("*-map/SKILL.md"))
        if p.parent.name not in EXCLUDE
    ]
    infra = ROOT / ".claude/skills/ippoan-infra-map/SKILL.md"
    if infra.exists():
        srcs.append(infra)
    return srcs


def parse_frontmatter(text: str) -> tuple[dict, str]:
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if not m:
        return {}, text
    fm: dict = {}
    for line in m.group(1).splitlines():
        mm = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if mm:
            fm[mm.group(1)] = mm.group(2).strip()
    return fm, m.group(2).lstrip("\n")


def resolve_owner(repo: str, haystack: str) -> str:
    """description / 本文中の `owner/repo` 記述から owner を解決 (既定 ippoan)。

    ローカルパス (`/home/user/...`) や upstream 引用 (`anthropics/...`) を
    owner と取り違えないよう、既知 org にマッチした最初の候補だけ採用する。
    """
    pat = r"([A-Za-z0-9][A-Za-z0-9_.-]*)/" + re.escape(repo) + r"(?![\w.-])"
    for m in re.finditer(pat, haystack):
        if m.group(1) in KNOWN_OWNERS:
            return m.group(1)
    return DEFAULT_OWNER


def repo_targets(fm: dict, body: str) -> list[tuple[str, str, str]]:
    """`generated-from` を [(owner, repo, sha), ...] に展開する (複数 repo 対応)。"""
    gf = fm.get("generated-from", "").strip()
    hay = fm.get("description", "") + "\n" + body
    out: list[tuple[str, str, str]] = []
    for token in gf.split():
        if ":" not in token:
            continue
        repo, sha = token.split(":", 1)
        out.append((resolve_owner(repo, hay), repo, sha))
    return out


def summary(body: str, fm: dict) -> str:
    """本文 H1 直後の最初の段落を概要として抜く。無ければ description 前半。"""
    started = False
    buf: list[str] = []
    for ln in body.splitlines():
        if not started:
            if ln.startswith("# "):
                started = True
            continue
        s = ln.strip()
        if not s:
            if buf:
                break
            continue
        if s[0] in "#>|-*!?" or s.startswith("```"):
            if buf:
                break
            continue
        buf.append(s)
    text = " ".join(buf).strip()
    if not text:
        text = re.split(r"トリガー[:：]", fm.get("description", ""))[0].strip()
    return text[:200]


def badge_block(targets: list[tuple[str, str, str]]) -> str:
    if not targets:
        return ""
    lines = ['!!! info "対象リポジトリ"']
    for owner, repo, sha in targets:
        note = (
            "空リポジトリ (プレースホルダ)"
            if sha == EMPTY_TREE
            else f"追従 tree `{sha[:7]}`"
        )
        lines.append(
            f"    - [{owner}/{repo}](https://github.com/{owner}/{repo}) — {note}"
        )
    return "\n".join(lines) + "\n"


def trigger_block(desc: str) -> str:
    if not desc:
        return ""
    return '??? note "検索トリガー語 (LLM 用)"\n    ' + desc.strip() + "\n"


def split_h1(body: str) -> tuple[str, str]:
    lines = body.splitlines()
    for i, ln in enumerate(lines):
        if ln.startswith("# "):
            return "\n".join(lines[: i + 1]), "\n".join(lines[i + 1 :])
    return "", body


def render_page(fm: dict, body: str) -> str:
    targets = repo_targets(fm, body)
    h1, rest = split_h1(body)
    parts: list[str] = []
    if h1:
        parts.append(h1)
    badge = badge_block(targets)
    if badge:
        parts.append(badge)
    trig = trigger_block(fm.get("description", ""))
    if trig:
        parts.append(trig)
    parts.append(rest.lstrip("\n"))
    return "\n\n".join(p for p in parts if p).rstrip() + "\n"


def category(name: str) -> str:
    if name == "ippoan-infra-map":
        return "基盤 / メタ"
    if name.startswith("nuxt"):
        return "フロントエンド (Nuxt / Workers)"
    return "バックエンド / Worker / ライブラリ"


CAT_ORDER = [
    "基盤 / メタ",
    "バックエンド / Worker / ライブラリ",
    "フロントエンド (Nuxt / Workers)",
]

CAT_ICON = {
    "基盤 / メタ": ":material-sitemap:",
    "バックエンド / Worker / ライブラリ": ":material-server-network:",
    "フロントエンド (Nuxt / Workers)": ":material-vuejs:",
}


def card_item(e: dict) -> str:
    """Material の grid cards 1 枚分の markdown を返す。"""
    icon = CAT_ICON.get(e["cat"], ":material-map-marker:")
    repos = " · ".join(
        f"[:octicons-mark-github-16: {o}/{r}](https://github.com/{o}/{r})"
        for o, r, _ in e["targets"]
    )
    lines = [
        f'-   {icon}{{ .lg .middle }} __[{e["name"]}](maps/{e["name"]}.md)__',
        "",
        "    ---",
        "",
        f'    {e["summary"]}',
    ]
    if repos:
        lines += ["", f"    {repos}"]
    return "\n".join(lines)


def main() -> None:
    MAPS_OUT.mkdir(parents=True, exist_ok=True)
    entries: list[dict] = []
    for src in map_sources():
        fm, body = parse_frontmatter(src.read_text(encoding="utf-8"))
        name = fm.get("name") or src.parent.name
        (MAPS_OUT / f"{name}.md").write_text(render_page(fm, body), encoding="utf-8")
        entries.append(
            {
                "name": name,
                "summary": summary(body, fm),
                "targets": repo_targets(fm, body),
                "cat": category(name),
            }
        )

    by_cat: dict[str, list] = {}
    for e in entries:
        by_cat.setdefault(e["cat"], []).append(e)
    cats = [c for c in CAT_ORDER if c in by_cat] + [
        c for c in by_cat if c not in CAT_ORDER
    ]

    # トップページ: カテゴリごとに grid cards
    out: list[str] = [
        "# ippoan リポジトリ構造マップ",
        "",
        "ippoan / ohishi 系リポジトリの **構造ナビゲーション** (どの repo の"
        "どこに何があるか) を 1 枚ずつまとめた閲覧サイト。コードを触る前に"
        "「どのファイルを見るか」を即断するための地図。",
        "",
        "各ページの Source of Truth は "
        "[`ippoan/claude-skills`](https://github.com/ippoan/claude-skills) の "
        "`<repo>-map/SKILL.md`。`main` への push で自動再生成・再デプロイされる。",
        "",
        f'!!! tip "収録マップ {len(entries)} 枚"',
        "    左のナビ (カテゴリ別) ・カード・上部の検索からどうぞ。"
        "各ページには対象 repo へのリンクと追従コミットのバッジが付く。",
        "",
    ]
    for cat in cats:
        out += [f"## {cat}", "", '<div class="grid cards" markdown>', ""]
        for e in sorted(by_cat[cat], key=lambda x: x["name"]):
            out += [card_item(e), ""]
        out += ["</div>", ""]
    DOCS.joinpath("index.md").write_text("\n".join(out) + "\n", encoding="utf-8")

    # 左ナビ (mkdocs-literate-nav): カテゴリでグルーピング
    sm: list[str] = ["* [ホーム](index.md)"]
    for cat in cats:
        sm.append(f"* {cat}")
        for e in sorted(by_cat[cat], key=lambda x: x["name"]):
            sm.append(f"    * [{e['name']}](maps/{e['name']}.md)")
    DOCS.joinpath("SUMMARY.md").write_text("\n".join(sm) + "\n", encoding="utf-8")

    print(f"generated {len(entries)} pages + index + SUMMARY -> {DOCS}")


if __name__ == "__main__":
    main()
