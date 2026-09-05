#!/usr/bin/env python3
"""PreToolUse / matcher: Bash — 公開される前に止める。

`gh pr create` / `gh issue create` / `gh pr comment` / `gh issue comment` のときだけ働き、
公開されるテキスト (`--title` / `--body` / `--body-file`) を scan_public_text に通す。
**対象 repo が public で当たったら deny**、private なら素通し (stderr へ警告)。

なぜ「PR が失敗してから」ではなく「作成の瞬間」か:
PR 本文は作った瞬間に公開ページと git 履歴へ載る。CI や分類器の deny を見てから直しても、
本文はもう出ている。**止めるなら作成前しかない。**

もう 1 つの役目: PermissionDenied hook が置いた走査結果 (pending) を回収し、
`additionalContext` としてモデルへ渡す。PermissionDenied の hookSpecificOutput は
`retry` しか持たない (= 当たった語を直接返す口が無い) ため、この 2 本で橋を架けている。
詳細は SKILL.md の「PermissionDenied で返せるもの」を参照。

escape: `~/.claude/state/public-text-guard/allow/<session_id>` が在れば素通し。
"""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts"))
from scan_public_text import format_findings, scan  # noqa: E402

STATE_DIR = os.path.join(
    os.environ.get("HOME", ""), ".claude", "state", "public-text-guard"
)
ALLOW_DIR = os.path.join(STATE_DIR, "allow")
PENDING_DIR = os.path.join(STATE_DIR, "pending")
PENDING_MAX_AGE_SEC = 900

# 公開される口だけを対象にする。`gh pr view` / `gh pr list` のような読み取り系は走査しない。
PUBLISHING_SUBCOMMANDS = {("pr", "create"), ("pr", "comment"),
                         ("issue", "create"), ("issue", "comment")}

TEXT_FLAGS = {"--title", "-t", "--body", "-b"}
FILE_FLAGS = {"--body-file", "-F"}
REPO_FLAGS = {"--repo", "-R"}
# shlex は演算子も 1 トークンとして返す。ここで次のコマンドとの境目を切る。
COMMAND_SEPARATORS = {"&&", "||", ";", "|", "&", "\n"}


def safe_session_id(session_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", session_id)


def drain_pending(session_id: str) -> str:
    """PermissionDenied hook が残した走査結果を 1 回だけ取り出す。"""
    if not session_id:
        return ""
    path = os.path.join(PENDING_DIR, safe_session_id(session_id) + ".txt")
    try:
        stat = os.stat(path)
        with open(path, encoding="utf-8", errors="replace") as fh:
            body = fh.read()
    except OSError:
        return ""
    try:
        os.unlink(path)
    except OSError:
        pass
    if time.time() - stat.st_mtime > PENDING_MAX_AGE_SEC:
        return ""
    return body.strip()


def split_commands(tokens: list[str]) -> list[list[str]]:
    """`&&` などで区切って、コマンドごとのトークン列にする。"""
    commands: list[list[str]] = [[]]
    for token in tokens:
        if token in COMMAND_SEPARATORS:
            commands.append([])
        else:
            commands[-1].append(token)
    return [c for c in commands if c]


def find_publishing_invocations(tokens: list[str]) -> list[list[str]]:
    """公開系の `gh <pr|issue> <create|comment>` だけを取り出す。"""
    found = []
    for command in split_commands(tokens):
        for i in range(len(command) - 2):
            if os.path.basename(command[i]) != "gh":
                continue
            if (command[i + 1], command[i + 2]) in PUBLISHING_SUBCOMMANDS:
                found.append(command[i + 3:])
                break
    return found


def _flag_value(args: list[str], index: int) -> tuple[str | None, int]:
    """`--body v` と `--body=v` の両方から値を取る。返り値は (値, 次の index)。"""
    arg = args[index]
    if "=" in arg and arg.startswith("--"):
        return arg.split("=", 1)[1], index + 1
    if index + 1 < len(args):
        return args[index + 1], index + 2
    return None, index + 1


def collect_public_text(args: list[str]) -> tuple[list[tuple[str, str]], str | None, list[str]]:
    """公開されるテキストと、対象 repo と、読めなかったファイルを集める。"""
    texts: list[tuple[str, str]] = []
    repo: str | None = None
    unreadable: list[str] = []

    i = 0
    while i < len(args):
        head = args[i].split("=", 1)[0]
        if head in TEXT_FLAGS:
            value, i = _flag_value(args, i)
            if value is not None:
                texts.append((head, value))
            continue
        if head in FILE_FLAGS:
            path, i = _flag_value(args, i)
            if path is None or path == "-":
                continue
            try:
                with open(os.path.expanduser(path), encoding="utf-8", errors="replace") as fh:
                    texts.append((path, fh.read()))
            except OSError:
                unreadable.append(path)
            continue
        if head in REPO_FLAGS:
            value, i = _flag_value(args, i)
            if value:
                repo = value
            continue
        i += 1
    return texts, repo, unreadable


def repo_visibility(repo: str | None) -> tuple[str, str | None]:
    """(visibility, 判定できなかった理由) を返す。判定不能なら "UNKNOWN"。"""
    cmd = ["gh", "repo", "view"]
    if repo:
        cmd.append(repo)
    cmd += ["--json", "visibility", "-q", ".visibility"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError) as exc:
        return "UNKNOWN", str(exc)
    if proc.returncode != 0:
        return "UNKNOWN", (proc.stderr or "").strip()[:200]
    return (proc.stdout or "").strip().upper() or "UNKNOWN", None


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0  # payload を読めないときは素通し (誤爆より取りこぼしを選ぶ)

    session_id = str(event.get("session_id") or "")
    pending = drain_pending(session_id)
    command = ((event.get("tool_input") or {}).get("command")) or ""

    try:
        tokens = shlex.split(command, comments=False)
    except ValueError:
        tokens = command.split()

    invocations = find_publishing_invocations(tokens)
    if not invocations:
        # 走査しない (読み取り系や gh 以外)。pending が在るときだけモデルへ渡す。
        if pending:
            emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "additionalContext": pending}})
        return 0

    if session_id and os.path.exists(os.path.join(ALLOW_DIR, safe_session_id(session_id))):
        sys.stderr.write(
            "[public-text-guard] escape ファイルが在るため走査を飛ばしました "
            "(%s)\n" % os.path.join(ALLOW_DIR, safe_session_id(session_id))
        )
        if pending:
            emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "additionalContext": pending}})
        return 0

    all_findings: list[tuple[str, list[tuple[int, str, str]]]] = []
    repo: str | None = None
    unreadable: list[str] = []
    sources: list[tuple[str, str]] = []
    for args in invocations:
        texts, found_repo, missed = collect_public_text(args)
        repo = repo or found_repo
        unreadable += missed
        sources += texts
    # フラグ解析に頼り切らず、コマンド全文も必ず走査する。
    # 引用が壊れて shlex が失敗した場合・heredoc・`--body "$(...)"` の中身は
    # フラグ単位では拾えないが、公開系 gh のコマンド全文に載っていれば当たる。
    sources.append(("(コマンド全文)", command))

    seen: set[tuple[str, str]] = set()
    for source, text in sources:
        findings = [f for f in scan(text) if (f[1], f[2]) not in seen]
        seen.update((f[1], f[2]) for f in findings)
        if findings:
            all_findings.append((source, findings))

    if not all_findings:
        if pending:
            emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "additionalContext": pending}})
        return 0

    visibility, why_unknown = repo_visibility(repo)
    detail = "\n".join(
        "%s:\n%s" % (source, format_findings(findings)) for source, findings in all_findings
    )

    if visibility == "PRIVATE":
        sys.stderr.write(
            "[public-text-guard] private repo (%s) なので素通ししましたが、"
            "次が本文に含まれています:\n%s\n" % (repo or "cwd", detail)
        )
        if pending:
            emit({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                         "additionalContext": pending}})
        return 0

    unknown_note = ""
    if visibility == "UNKNOWN":
        unknown_note = (
            "\n(repo の visibility を判定できなかったため public として扱いました: %s)"
            % (why_unknown or "理由不明")
        )
    unreadable_note = ""
    if unreadable:
        unreadable_note = "\n(読めなかった --body-file: %s)" % ", ".join(unreadable)

    reason = (
        "公開される本文に本番識別子・資格情報が含まれています。"
        "PR / issue は作成した瞬間に公開ページと git 履歴へ載るので、作成前に止めました。\n"
        "%s%s%s\n\n"
        "値を伏せてから (プレースホルダに置換するか、その行ごと落として) やり直してください。\n"
        "検査が誤爆している場合だけ、次のファイルを作れば このセッションでは素通しします:\n"
        "  %s\n"
        "%s" % (
            detail,
            unknown_note,
            unreadable_note,
            os.path.join(ALLOW_DIR, safe_session_id(session_id) or "<session_id>"),
            pending and ("\n直前の拒否についての走査結果:\n" + pending) or "",
        )
    )
    emit({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
