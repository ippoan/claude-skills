#!/usr/bin/env python3
"""公開されるテキストから本番識別子・資格情報を探す唯一のスキャナ。

2 本の hook (PreToolUse / PermissionDenied) が **どちらもこのモジュールを import する**。
判定ロジックを 2 か所に分けると必ず食い違うので、パターンはここにしか書かない。

CLI:
    scan_public_text.py [FILE]      # FILE 省略時は stdin
    出力: `行番号:種別:語` を 1 行 1 件。当たりがあれば exit 1、無ければ exit 0。

方針は「取りこぼしより誤爆を嫌う」。誤爆する検査は使われなくなり、使われない検査は
何も守らないため。git SHA・プレースホルダ・英単語・**パス様トークンの中の UUID** は
当てない (`_is_device_credential` / `_is_placeholder_uuid` / `_is_path_uuid` を参照)。

内部ホスト名のような **repo に書けない語** はここに書かず、
`~/.claude/state/public-text-guard/denylist` (1 行 1 語) から読む。
"""

from __future__ import annotations

import os
import re
import sys

STATE_DIR = os.path.join(
    os.environ.get("HOME", ""), ".claude", "state", "public-text-guard"
)
DENYLIST_PATH = os.path.join(STATE_DIR, "denylist")

# --- パターン ---------------------------------------------------------------

# UUID (device_id / tenant_id はこの形)。大文字表記も同じ機密なので case-insensitive。
UUID_RE = re.compile(
    r"(?<![0-9A-Za-z-])"
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    r"(?![0-9A-Za-z-])"
)

# 明らかな資格情報。prefix さえ在れば尻尾が短くても資格情報なので下限は緩い。
CREDENTIAL_RES = [
    ("github-token", re.compile(r"github_pat_[A-Za-z0-9_]{3,}")),
    ("github-token", re.compile(r"\bghp_[A-Za-z0-9_]{3,}")),
    ("github-token", re.compile(r"\bgho_[A-Za-z0-9_]{3,}")),
    ("api-key", re.compile(r"\bsk-[A-Za-z0-9_-]{8,}")),
    ("aws-key", re.compile(r"\bAKIA[0-9A-Z]{8,}")),
    ("private-key", re.compile(r"-----BEGIN[A-Z ]*")),
]

# device credential 風: base64url 20〜24 文字。
# ここが一番誤爆しやすいので、下の _is_device_credential で厳しく絞る。
TOKENISH_RE = re.compile(r"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{20,24}(?![A-Za-z0-9_-])")

HEX_ONLY_RE = re.compile(r"[0-9a-fA-F]+\Z")


def _is_placeholder_uuid(match: str) -> bool:
    """`00000000-0000-0000-0000-000000000000` のような見本を除外する。

    16 進の中身が 1 種類の文字だけで出来ていれば、それは値ではなく形の説明。
    """
    return len(set(match.replace("-", "").lower())) == 1


def _is_path_uuid(line: str, span: tuple[int, int]) -> bool:
    """`/tmp/…/<UUID>/scratchpad` のような**パスの中の** UUID を除外する。

    空白で区切った語に `/` が在れば、それは公開される値ではなく作業パス。
    公開文に載る UUID は `device_id=…` のように語として立つ。

    コマンド全文を走査する以上ここは必ず視界へ入り、実運用の 1 本目で
    2 回続けて誤爆した (#157)。誤爆する検査は外され、外れた検査は何も守らない。
    """
    start, end = span
    while start > 0 and not line[start - 1].isspace():
        start -= 1
    while end < len(line) and not line[end].isspace():
        end += 1
    return "/" in line[start:end]


def _is_device_credential(token: str) -> bool:
    """base64url 20〜24 文字のうち、本物の credential らしいものだけ真を返す。

    落とすもの (どれも公開文に普通に現れる):
      - 16 進だけ …… git SHA・hex id。**git SHA を弾かないための最重要条件**
      - 10 進だけ …… 連番・エポック秒
      - 大文字/小文字/数字 のどれかを欠くもの …… `internationalization` のような英単語や
        kebab-case の識別子 (`public-text-guard-hook` 等) がここで落ちる
    """
    if HEX_ONLY_RE.match(token):
        return False
    if token.isdigit():
        return False
    has_upper = any(c.isupper() for c in token)
    has_lower = any(c.islower() for c in token)
    has_digit = any(c.isdigit() for c in token)
    return has_upper and has_lower and has_digit


def load_denylist(path: str = DENYLIST_PATH) -> list[str]:
    """内部ホスト名などの語を state から読む。無ければ空 (= 検査しない)。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError:
        return []
    words = []
    for line in raw.splitlines():
        word = line.strip()
        if word and not word.startswith("#"):
            words.append(word)
    return words


def redact(kind: str, match: str) -> str:
    """資格情報は伏せて出す。UUID / denylist 語はそのまま出す。

    伏せる理由と出す理由は別々にある:
      - 資格情報を全文で transcript に再掲すると、止めた先で漏れが増える
      - UUID と denylist 語は「本文のどれを直せばいいか」を指すための値なので、
        伏せると hook の用が足りない (元の command には既に載っている)
    """
    if kind in ("uuid", "denylist"):
        return match
    if len(match) <= 12:
        return match
    return match[:8] + "…(以下 %d 文字)" % (len(match) - 8)


def scan(text: str, denylist: list[str] | None = None) -> list[tuple[int, str, str]]:
    """テキストを走査し `(行番号, 種別, 語)` の一覧を返す。当たりが無ければ空。"""
    if denylist is None:
        denylist = load_denylist()

    findings: list[tuple[int, str, str]] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        # 同じ文字位置を 2 種類で二重報告しないための占有範囲。
        claimed: list[tuple[int, int]] = []

        def _claim(span: tuple[int, int]) -> bool:
            for start, end in claimed:
                if span[0] < end and start < span[1]:
                    return False
            claimed.append(span)
            return True

        for m in UUID_RE.finditer(line):
            if _is_placeholder_uuid(m.group(0)) or _is_path_uuid(line, m.span()):
                _claim(m.span())  # 見本もパスも占有はする (device 風で拾い直さないため)
                continue
            if _claim(m.span()):
                findings.append((lineno, "uuid", m.group(0)))

        for kind, regex in CREDENTIAL_RES:
            for m in regex.finditer(line):
                if _claim(m.span()):
                    findings.append((lineno, kind, m.group(0)))

        for m in TOKENISH_RE.finditer(line):
            token = m.group(0)
            if not _is_device_credential(token):
                continue
            if _claim(m.span()):
                findings.append((lineno, "device-credential", token))

        low = line.lower()
        for word in denylist:
            idx = low.find(word.lower())
            if idx >= 0 and _claim((idx, idx + len(word))):
                findings.append((lineno, "denylist", word))

    findings.sort(key=lambda f: (f[0], f[1]))
    return findings


def format_findings(findings: list[tuple[int, str, str]]) -> str:
    """deny 文言や hook の出力にそのまま貼れる形に整える。"""
    return "\n".join(
        "  行 %d: %s (%s)" % (lineno, redact(kind, match), kind)
        for lineno, kind, match in findings
    )


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        with open(argv[1], encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()
    findings = scan(text)
    for lineno, kind, match in findings:
        print("%d:%s:%s" % (lineno, kind, redact(kind, match)))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
