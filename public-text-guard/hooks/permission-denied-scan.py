#!/usr/bin/env python3
"""PermissionDenied hook — 拒否の瞬間に原因を提示する。

拒否された tool 呼び出しの中身を scan_public_text に通し、**2 分岐**で返す:

  当たった  → 「これが拒否の原因である可能性が高い。値を伏せて 1 回だけ再試行せよ」
              (`retry: true` を返す = モデルは再試行してよいと明示される)
  当たらない → 「検出されなかった。推測で再試行するな。拒否文言を引用して人へ上げよ」
              (`retry` を返さない = モデルは再試行を促されない)

「点検せずに人へ投げる」と「原因不明のまま再試行する」の**両方**を止めるのが要点。

## PermissionDenied で返せるもの (実測、claude 2.1.239)

このイベントの `hookSpecificOutput` は **`{hookEventName, retry?}` しか受け付けない**
(`additionalContext` は無い)。stdout は transcript (ctrl+o) 表示のみ、
`systemMessage` はユーザー向け UI のみ。**当たった語をモデルへ直接返す口が無い。**

そこで「retry ビット」で分岐の意味だけを伝え、**語と行は pending ファイルへ書く**。
同じセッションの次の Bash 呼び出し (= たいていは同じコマンドの再試行) で
PreToolUse hook がそれを回収し、`additionalContext` としてモデルへ渡す。
再試行が公開系の gh なら、PreToolUse が同じスキャナで改めて deny するので、
そちらの文言でも当たった語が出る。

もう 1 つの実測: このイベントは **auto mode 分類器による deny のときだけ**発火する
(`decisionReason.classifier === "auto-mode"`)。allow ルール外の通常の確認や
ユーザーの拒否では回らない。
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
from scan_public_text import format_findings, scan  # noqa: E402

STATE_DIR = os.path.join(
    os.environ.get("HOME", ""), ".claude", "state", "public-text-guard"
)
PENDING_DIR = os.path.join(STATE_DIR, "pending")

FILE_FLAGS = {"--body-file", "-F"}

HIT_TEMPLATE = """[public-text-guard] 拒否された {tool} 呼び出しに次が含まれていました:
{detail}

**これが拒否の原因である可能性が高い。** 値を伏せてから 1 回だけ再試行してください。
ユーザーへ escalate する前にこれを直すこと。
(拒否の文言: {reason})"""

MISS_TEMPLATE = """[public-text-guard] 拒否された {tool} 呼び出しを走査しましたが、\
本番識別子・資格情報は**検出されませんでした**。

**推測で再試行しないこと。** 拒否の文言をそのまま引用してユーザーへ上げてください。
(拒否の文言: {reason})"""


def safe_session_id(session_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", session_id)


def _read_body_files(command: str) -> list[str]:
    """`--body-file <path>` が指すファイルの中身も走査対象に含める。"""
    try:
        tokens = shlex.split(command, comments=False)
    except ValueError:
        return []
    texts = []
    for i, token in enumerate(tokens):
        head, _, inline = token.partition("=")
        if head not in FILE_FLAGS:
            continue
        path = inline if inline else (tokens[i + 1] if i + 1 < len(tokens) else "")
        if not path or path == "-":
            continue
        try:
            with open(os.path.expanduser(path), encoding="utf-8", errors="replace") as fh:
                texts.append(fh.read())
        except OSError:
            continue
    return texts


def _string_leaves(value) -> list[str]:
    """未知の tool のために、tool_input の文字列を全部拾う。

    走査していない中身について「検出されませんでした」と言い切らないための保険。
    """
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        return [s for v in value.values() for s in _string_leaves(v)]
    if isinstance(value, list):
        return [s for v in value for s in _string_leaves(v)]
    return []


def collect_texts(tool_name: str, tool_input: dict) -> list[str]:
    if tool_name == "Bash":
        command = tool_input.get("command") or ""
        return [command] + _read_body_files(command)
    if tool_name == "Write":
        return [tool_input.get("content") or ""]
    if tool_name == "Edit":
        return [tool_input.get("new_string") or ""]
    return _string_leaves(tool_input)


def write_pending(session_id: str, message: str) -> None:
    """次の Bash 呼び出しで PreToolUse が拾えるよう、走査結果を残す。"""
    if not session_id:
        return
    try:
        os.makedirs(PENDING_DIR, exist_ok=True)
        path = os.path.join(PENDING_DIR, safe_session_id(session_id) + ".txt")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(message)
    except OSError:
        pass


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0

    tool_name = str(event.get("tool_name") or "不明な tool")
    tool_input = event.get("tool_input") or {}
    reason = str(event.get("reason") or "(理由なし)").strip()
    session_id = str(event.get("session_id") or "")

    findings: list[tuple[int, str, str]] = []
    for text in collect_texts(tool_name, tool_input if isinstance(tool_input, dict) else {}):
        findings += scan(text)

    if findings:
        message = HIT_TEMPLATE.format(
            tool=tool_name, detail=format_findings(findings), reason=reason
        )
        output = {
            "systemMessage": message,
            "hookSpecificOutput": {"hookEventName": "PermissionDenied", "retry": True},
        }
    else:
        message = MISS_TEMPLATE.format(tool=tool_name, reason=reason)
        # retry を返さない。「原因不明のまま再試行する」を促さないため。
        output = {"systemMessage": message}

    write_pending(session_id, message)
    # stdout は JSON だけにする (Claude Code が JSON として解釈する口なので、
    # 人向けの文を混ぜると壊れる)。人へは systemMessage が出る。
    print(json.dumps(output, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
