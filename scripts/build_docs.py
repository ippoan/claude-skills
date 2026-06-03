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


# repo の「役割 (業務ドメイン / 機能)」でグルーピングする。name → カテゴリ。
ROLE = {
    # 開発・CCoW 基盤
    "ippoan-infra-map": "開発・CCoW 基盤",
    "claude-skills-map": "開発・CCoW 基盤",
    "ref-files-worker-map": "開発・CCoW 基盤",
    "ui-preview-map": "開発・CCoW 基盤",
    # CI/CD・リリース
    "ci-workflows-map": "CI/CD・リリース",
    "ci-dashboard-map": "CI/CD・リリース",
    "release-wave-gcp-map": "CI/CD・リリース",
    # 認証・Secret 管理
    "auth-worker-map": "認証・Secret 管理",
    "secrets-inventory-map": "認証・Secret 管理",
    "secrets-inventory-gcp-map": "認証・Secret 管理",
    # 運行管理・アルコールチェック
    "rust-alc-api-map": "運行管理・アルコールチェック",
    "alc-app-map": "運行管理・アルコールチェック",
    "nuxt-pwa-carins-map": "運行管理・アルコールチェック",
    "nuxt-trouble-map": "運行管理・アルコールチェック",
    "nuxt-notify-map": "運行管理・アルコールチェック",
    "nuxt_dtako_logs-map": "運行管理・アルコールチェック",
    "nuxt-dtako-admin-map": "運行管理・アルコールチェック",
    "dtako-scraper-map": "運行管理・アルコールチェック",
    # 売上分析 (一番星)
    "rust-ichibanboshi-map": "売上分析 (一番星)",
    "nuxt-ichibanboshi-map": "売上分析 (一番星)",
    # e-Gov 電子申請
    "egov-shinsei-sdk-map": "e-Gov 電子申請",
    "nuxt-egov-map": "e-Gov 電子申請",
    # ヘルスケア
    "HealthConnectReader-map": "ヘルスケア",
    "HealthConnectReaderWorker-map": "ヘルスケア",
    # その他業務
    "freee-map": "その他業務 (会計 / 物品)",
    "nuxt-items-map": "その他業務 (会計 / 物品)",
    # 未分類
    "ippoan-drift-map": "未分類 / プレースホルダ",
}
DEFAULT_ROLE = "その他"


def category(name: str) -> str:
    return ROLE.get(name, DEFAULT_ROLE)


CAT_ORDER = [
    "開発・CCoW 基盤",
    "CI/CD・リリース",
    "認証・Secret 管理",
    "運行管理・アルコールチェック",
    "売上分析 (一番星)",
    "e-Gov 電子申請",
    "ヘルスケア",
    "その他業務 (会計 / 物品)",
    "未分類 / プレースホルダ",
]

CAT_ICON = {
    "開発・CCoW 基盤": ":material-cog-outline:",
    "CI/CD・リリース": ":material-rocket-launch-outline:",
    "認証・Secret 管理": ":material-shield-key-outline:",
    "運行管理・アルコールチェック": ":material-truck-outline:",
    "売上分析 (一番星)": ":material-chart-line:",
    "e-Gov 電子申請": ":material-file-document-outline:",
    "ヘルスケア": ":material-heart-pulse:",
    "その他業務 (会計 / 物品)": ":material-briefcase-outline:",
    "未分類 / プレースホルダ": ":material-help-circle-outline:",
}

# tree 表示用の Unicode 絵文字 (<pre> 内では :material-...: shortcode が
# 展開されないため直接の絵文字を使う)。
CAT_EMOJI = {
    "開発・CCoW 基盤": "⚙️",
    "CI/CD・リリース": "🚀",
    "認証・Secret 管理": "🔑",
    "運行管理・アルコールチェック": "🚚",
    "売上分析 (一番星)": "📈",
    "e-Gov 電子申請": "📄",
    "ヘルスケア": "🩺",
    "その他業務 (会計 / 物品)": "💼",
    "未分類 / プレースホルダ": "❓",
}


def _plain(s: str) -> str:
    """summary から markdown 装飾 (bold / code / link) を除去する。"""
    s = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)
    s = re.sub(r"`([^`]+)`", r"\1", s)
    return s.replace("**", "").replace("`", "").strip()


def _short(summary: str, limit: int = 60) -> str:
    """tree の右に出す 1 行概要 (markdown 除去 + 最初の文 / limit 字)。"""
    desc = _plain(summary).split("。")[0].strip()
    return desc[:limit] + "…" if len(desc) > limit else desc


def render_tree(by_cat: dict, cats: list) -> str:
    """カテゴリ → repo を ├─ └─ の罫線ツリーで描く (<pre> + リンク + 概要)。"""
    names = [e["name"] for es in by_cat.values() for e in es]
    width = max((len(n) for n in names), default=0)
    lines = ['<pre class="repo-tree">', "ippoan repo マップ"]
    for ci, cat in enumerate(cats):
        clast = ci == len(cats) - 1
        emoji = CAT_EMOJI.get(cat, "")
        lines.append(f'{"└─" if clast else "├─"} {emoji} {cat}')
        cont = "   " if clast else "│  "
        entries = sorted(by_cat[cat], key=lambda x: x["name"])
        for ei, e in enumerate(entries):
            elast = ei == len(entries) - 1
            branch = "└─" if elast else "├─"
            name = e["name"]
            link = f'<a href="maps/{name}.html">{name}</a>'
            pad = " " * (width - len(name))
            lines.append(f'{cont}{branch} {link}{pad}  <span class="t-desc">{_short(e["summary"])}</span>')
    lines.append("</pre>")
    return "\n".join(lines)


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
    out += ["## 役割マップ", "", render_tree(by_cat, cats), ""]
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
