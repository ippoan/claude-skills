#!/usr/bin/env python3
"""public-text-guard の 2 hook を、サンプル payload で機械検証する。

`HOME` を一時ディレクトリへ差し替え、`gh` を PATH 上の stub に差し替えて回すので、
**`~/.claude/state/` の実物にも本物の GitHub にも触らない**。

    python3 public-text-guard/tests/run_tests.py

全ケース PASS なら exit 0、1 つでも落ちたら exit 1。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PRETOOL = os.path.join(ROOT, "hooks", "pretool-public-text-guard.py")
DENIED = os.path.join(ROOT, "hooks", "permission-denied-scan.py")

# テストに実在の本番識別子や内部ホスト名を書かないための、明らかな作り物。
SAMPLE_UUID = "3f2a91c4-7b6e-4d15-9a80-c2e5b41f70d8"
PLACEHOLDER_UUID = "00000000-0000-0000-0000-000000000000"
GIT_SHA = "5c6d28928bd54f1a9e07b3c8d2416af07be91d3c"  # 40 桁 hex
FAKE_TOKEN = "ghp_xxxx"
DENYLIST_WORD = "internal-example-host.invalid"

GH_STUB = """#!/bin/sh
# gh repo view <repo> --json visibility -q .visibility だけを模す stub。
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo "${FAKE_GH_VISIBILITY:-PUBLIC}"
  exit 0
fi
echo "gh stub: unsupported args: $*" >&2
exit 1
"""


class Sandbox:
    """HOME と PATH を差し替えた使い捨て環境。"""

    def __init__(self) -> None:
        self.dir = tempfile.mkdtemp(prefix="public-text-guard-test-")
        self.home = os.path.join(self.dir, "home")
        self.bin = os.path.join(self.dir, "bin")
        self.work = os.path.join(self.dir, "work")
        for path in (self.home, self.bin, self.work):
            os.makedirs(path, exist_ok=True)
        stub = os.path.join(self.bin, "gh")
        with open(stub, "w", encoding="utf-8") as fh:
            fh.write(GH_STUB)
        os.chmod(stub, 0o755)

    def state(self, *parts: str) -> str:
        return os.path.join(self.home, ".claude", "state", "public-text-guard", *parts)

    def write(self, path: str, content: str) -> str:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return path

    def env(self, visibility: str = "PUBLIC") -> dict:
        env = dict(os.environ)
        env["HOME"] = self.home
        env["PATH"] = self.bin + os.pathsep + env.get("PATH", "")
        env["FAKE_GH_VISIBILITY"] = visibility
        return env

    def cleanup(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)


def run_hook(script: str, payload: dict, sandbox: Sandbox, visibility: str = "PUBLIC"):
    proc = subprocess.run(
        [sys.executable, script],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=sandbox.env(visibility),
        cwd=sandbox.work,
        timeout=30,
    )
    parsed = None
    out = proc.stdout.strip()
    if out.startswith("{"):
        try:
            parsed = json.loads(out)
        except ValueError:
            parsed = None
    return proc, parsed


def bash_payload(command: str, session_id: str = "sess-test") -> dict:
    return {
        "session_id": session_id,
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "tool_use_id": "toolu_test",
    }


def denied_payload(tool_name: str, tool_input: dict, session_id: str = "sess-test") -> dict:
    return {
        "session_id": session_id,
        "hook_event_name": "PermissionDenied",
        "tool_name": tool_name,
        "tool_input": tool_input,
        "tool_use_id": "toolu_test",
        "reason": "Blocked by classifier.",
    }


def decision(parsed) -> str:
    """PreToolUse の判定を 'deny' / 'pass' に畳む。"""
    if not parsed:
        return "pass"
    return (parsed.get("hookSpecificOutput") or {}).get("permissionDecision") or "pass"


def reason(parsed) -> str:
    if not parsed:
        return ""
    return (parsed.get("hookSpecificOutput") or {}).get("permissionDecisionReason") or ""


# --- ケース -----------------------------------------------------------------

def case_01(sb):
    """1 | hook 1 | public repo + --body-file に UUID | deny + 当たった行"""
    body = sb.write(os.path.join(sb.work, "body.md"), "## 概要\n\ndevice_id=%s\n" % SAMPLE_UUID)
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr create --repo ippoan/claude-skills --title t --body-file %s" % body), sb)
    ok = decision(parsed) == "deny" and SAMPLE_UUID in reason(parsed) and "行 3" in reason(parsed)
    return ok, "decision=%s / 文言に行と語=%s" % (
        decision(parsed), "有" if SAMPLE_UUID in reason(parsed) and "行 3" in reason(parsed) else "無")


def case_02(sb):
    """2 | hook 1 | public repo + --body に ghp_xxxx | deny"""
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh issue create --repo ippoan/claude-skills --title t --body 'token: %s'" % FAKE_TOKEN), sb)
    ok = decision(parsed) == "deny" and FAKE_TOKEN in reason(parsed)
    return ok, "decision=%s / 語=%s" % (decision(parsed), FAKE_TOKEN if FAKE_TOKEN in reason(parsed) else "無")


def case_03(sb):
    """3 | hook 1 | public repo + 本文に 40 桁 hex (git SHA) のみ | 素通し"""
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr create --repo ippoan/claude-skills --title t --body '基点 %s'" % GIT_SHA), sb)
    ok = decision(parsed) == "pass"
    return ok, "decision=%s (stdout=%r)" % (decision(parsed), proc.stdout.strip()[:80])


def case_04(sb):
    """4 | hook 1 | public repo + 全ゼロ UUID (プレースホルダ) | 素通し"""
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr create --repo ippoan/claude-skills --title t --body 'device_id=%s'" % PLACEHOLDER_UUID), sb)
    ok = decision(parsed) == "pass"
    return ok, "decision=%s" % decision(parsed)


def case_05(sb):
    """5 | hook 1 | private repo + UUID | 素通し (stderr へ警告)"""
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr create --repo ippoan/secret --title t --body 'device_id=%s'" % SAMPLE_UUID),
        sb, visibility="PRIVATE")
    ok = decision(parsed) == "pass" and "private repo" in proc.stderr
    return ok, "decision=%s / stderr 警告=%s" % (decision(parsed), "有" if "private repo" in proc.stderr else "無")


def case_06(sb):
    """6 | hook 1 | escape ファイル有 + UUID | 素通し"""
    sb.write(sb.state("allow", "sess-escape"), "")
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr create --repo ippoan/claude-skills --title t --body 'device_id=%s'" % SAMPLE_UUID,
        session_id="sess-escape"), sb)
    ok = decision(parsed) == "pass" and "escape" in proc.stderr
    return ok, "decision=%s / stderr=%s" % (decision(parsed), "escape 通知有" if "escape" in proc.stderr else "無")


def case_07(sb):
    """7 | hook 1 | gh pr view (読み取り系) | 素通し・走査しない"""
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr view 153 --repo ippoan/claude-skills --json body  # %s" % SAMPLE_UUID), sb)
    ok = decision(parsed) == "pass" and proc.stdout.strip() == "" and proc.stderr.strip() == ""
    return ok, "decision=%s / 出力なし=%s" % (
        decision(parsed), "はい" if not proc.stdout.strip() and not proc.stderr.strip() else "いいえ")


def case_08(sb):
    """8 | hook 1 | denylist に語を置き本文にその語 | deny"""
    sb.write(sb.state("denylist"), "# 内部ホスト名\n%s\n" % DENYLIST_WORD)
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr comment 153 --repo ippoan/claude-skills --body 'https://%s/health'" % DENYLIST_WORD), sb)
    ok = decision(parsed) == "deny" and DENYLIST_WORD in reason(parsed)
    return ok, "decision=%s / 語=%s" % (decision(parsed), DENYLIST_WORD if DENYLIST_WORD in reason(parsed) else "無")


def case_09(sb):
    """9 | hook 2 | 拒否された Bash の command に UUID | 「原因の可能性が高い」"""
    proc, parsed = run_hook(DENIED, denied_payload("Bash", {
        "command": "gh pr create --title t --body 'device_id=%s'" % SAMPLE_UUID}), sb)
    msg = (parsed or {}).get("systemMessage", "")
    retry = ((parsed or {}).get("hookSpecificOutput") or {}).get("retry")
    ok = "拒否の原因である可能性が高い" in msg and SAMPLE_UUID in msg and retry is True
    return ok, "retry=%s / 文言=%s" % (retry, "原因の可能性 + 語 有" if SAMPLE_UUID in msg else "不足")


def case_10(sb):
    """10 | hook 2 | 拒否された Bash に何も当たらない | 「検出されませんでした」"""
    proc, parsed = run_hook(DENIED, denied_payload("Bash", {
        "command": "gh pr create --title t --body '基点 %s の修正'" % GIT_SHA}), sb)
    msg = (parsed or {}).get("systemMessage", "")
    retry = ((parsed or {}).get("hookSpecificOutput") or {}).get("retry")
    ok = ("検出されませんでした" in msg and "推測で再試行しないこと" in msg and retry is None)
    return ok, "retry=%s / 文言=%s" % (retry, "検出なし + 推測再試行禁止 有" if "検出されませんでした" in msg else "不足")


def case_11(sb):
    """11 | hook 2 | 拒否された Write の content に ghp_ | 検出される"""
    proc, parsed = run_hook(DENIED, denied_payload("Write", {
        "file_path": "/tmp/x.env", "content": "GH_TOKEN=%s\n" % FAKE_TOKEN}), sb)
    msg = (parsed or {}).get("systemMessage", "")
    retry = ((parsed or {}).get("hookSpecificOutput") or {}).get("retry")
    ok = FAKE_TOKEN in msg and retry is True
    return ok, "retry=%s / 語=%s" % (retry, FAKE_TOKEN if FAKE_TOKEN in msg else "無")


def case_12(sb):
    """12 | hook 1 | 引用が壊れて shlex が失敗するコマンド | deny (回帰防止)"""
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr create --repo ippoan/claude-skills --body 'unclosed %s" % SAMPLE_UUID), sb)
    ok = decision(parsed) == "deny" and SAMPLE_UUID in reason(parsed)
    return ok, "decision=%s (フラグ解析に失敗してもコマンド全文で当たる)" % decision(parsed)


def case_13(sb):
    """13 | hook 1 | heredoc で --body-file - に UUID | deny (回帰防止)"""
    proc, parsed = run_hook(PRETOOL, bash_payload(
        "gh pr create --repo ippoan/claude-skills --title t --body-file - <<'EOF'\n"
        "device_id=%s\nEOF" % SAMPLE_UUID), sb)
    ok = decision(parsed) == "deny" and SAMPLE_UUID in reason(parsed)
    return ok, "decision=%s (stdin 本文もコマンド全文に載っていれば当たる)" % decision(parsed)


# 1〜11 は issue #153 の受け入れ条件そのもの。12〜13 は実装中に見つけた
# すり抜け (フラグ解析だけに頼ると素通しした) の回帰防止。
CASES = [case_01, case_02, case_03, case_04, case_05, case_06,
         case_07, case_08, case_09, case_10, case_11,
         case_12, case_13]


def main() -> int:
    failures = 0
    print("=== public-text-guard hook tests (HOME / gh を差し替えて実行) ===")
    for case in CASES:
        sandbox = Sandbox()
        try:
            ok, detail = case(sandbox)
        except Exception as exc:  # noqa: BLE001
            ok, detail = False, "例外: %r" % (exc,)
        finally:
            sandbox.cleanup()
        title = (case.__doc__ or case.__name__).strip().splitlines()[0]
        print("%-4s %s\n       -> %s" % ("PASS" if ok else "FAIL", title, detail))
        if not ok:
            failures += 1
    print("=== %d/%d PASS ===" % (len(CASES) - failures, len(CASES)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
