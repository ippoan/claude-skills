---
name: open-multirepo-smoke
description: Generate a claude.ai/code launch URL pre-loaded with a smoke-test prompt for the github-mcp-server-rs 1-click pair flow (now monorepo'd into ippoan/mcp-relay-rs; original issue ippoan/github-mcp-server-rs#42 archived). Use when the user wants to verify a fresh CCoW container reaches the acceptance criteria end-to-end — no device-code prompt, pair_url on one stderr line, browser click → WS 101 within 5s, tools/list returns 40, and the negative paths (missing $GITHUB_LOGIN error, $GITHUB_MCP_AUTO_DEVICE_FLOW=1 opt-in) behave correctly. Output is a Markdown launch link plus a copy-pasteable smoke-test prompt; nothing is posted automatically.
---

# open-multirepo-smoke

Spawn a fresh Claude Code on the Web (CCoW) session pre-loaded with a smoke-test prompt that exercises the 1-click pair flow (originally ippoan/github-mcp-server-rs#42, archived; binary now lives in ippoan/mcp-relay-rs/binaries/github-mcp-server-rs, paired with ippoan/auth-worker#144).

This is a specialisation of `/open-multirepo` — the URL-building rules and "explicit list vs descriptive mention" heuristics are identical, but the prompt body is canned: a 6-step smoke test walking through the issue's Acceptance section.

## Arguments

User input may include:

- **Binary tag / PR ref / branch** to test (optional). Examples:
  - `v0.0.15` → smoke against a release tag (uses `GITHUB_MCP_PIN_TAG`)
  - `#50` → smoke against the PR head (build from the branch in the session)
  - `claude/implement-pair-subcommand-lSOf7` → build from the named branch
  - 省略 → use whatever `latest` resolves to in the session
- **Override repos** (optional, comma-separated `owner/repo` BEFORE any prose). Same explicit-vs-descriptive rules as `/open-multirepo`. Default = full MCP scope.
- **Extra notes** to append to the canned prompt (optional free text).

## Repo defaults

Same hard rule as `/open-multirepo`: default attaches **every repo the current session has GitHub MCP scope for**. Read the list from the system prompt's "restricted to the following repositories" block. Cross-repo verification (binary in `mcp-relay-rs/binaries/github-mcp-server-rs`, server in `auth-worker`, consumer hook chain in `cc-relay` / `claude-hooks` / `claude-md`) usually needs the full set anyway, so over-attaching is safer than under-attaching.

If the user passes an explicit comma-separated list before any prose, narrow to that list — same rules as the parent skill.

## Canned prompt skeleton

The skill assembles a prompt of this shape and then URL-encodes it. Fill in `<TAG_OR_BRANCH_HINT>` from the user's argument; if no hint, omit step 1's pin line.

```
github-mcp-server-rs 1-click pair flow (元: ippoan/github-mcp-server-rs#42, archived;
現行は ippoan/mcp-relay-rs/binaries/github-mcp-server-rs に統合) の smoke test を
CCoW container で実行する。

前提:
- 元 PR: ippoan/github-mcp-server-rs#50 (archived; claude/implement-pair-subcommand-lSOf7) — 後続は mcp-relay-rs の同名 path 配下
- server 側 (auth-worker#144 / PR #146) は staging に live
- target binary: <TAG_OR_BRANCH_HINT or "latest release">

手順:
1. CCoW container の Environment variables に `GITHUB_LOGIN` が set されていることを確認する
   (本人の github username; pair flow の claim_login として送信される)。
   未設定なら `[install-mcp]` が error で停止する仕様 — それも一度確認しておく。
2. session-start hook (`.claude/hooks/session-start.sh` → install-mcp.sh) が
   自動的に走ったあとの `$CLAUDE_PROJECT_DIR/.claude/mcp-state/` を確認:
     - `pair.log` に `https://auth(-staging).ippoan.org/mcp/pair/<code>` が 1 行 surface
     - `pair.pid` の process が生きている
     - device-code prompt (`Open this URL in your browser…`) は出ていない
3. pair.log の URL をブラウザで開いて 1 click。
4. 5s 以内に `mcp-state/url` が書かれ、`$GITHUB_MCP_URL` が export されることを確認。
5. Claude Code Web の MCP settings に登録済の `$GITHUB_MCP_URL` から `tools/list`
   を叩いて 40 tools が返ることを確認 (whoami + list_repos + Phase 1-3 admin)。
6. 反対方向もチェック:
   - `GITHUB_LOGIN` を unset で hook を再走させると `[install-mcp] ERROR: $GITHUB_LOGIN is not set` で停止する
   - `GITHUB_MCP_AUTO_DEVICE_FLOW=1` を set すると従来の device-code prompt 経路に戻る

合否を判定したら、binary repo の `docs/smoke-tests/<YYYY-MM-DD>-pair-flow.md` に
結果を 1 page 記録して PR #50 にコメントで報告する (PASS なら merge 可、FAIL なら
何が崩れたかを section にまとめる)。

詳細仕様は元 issue ippoan/github-mcp-server-rs#42 (archived) の Acceptance 節、および直前 session の
docs/smoke-tests/2026-05-18-admin-auth-option-f.md (auth-worker / mcp-relay-rs の
binaries/github-mcp-server-rs/docs/smoke-tests/ 両方に存在) を参照。
```

If the user passed extra notes, append them as a final `追記:` paragraph.

## Behavior

1. Resolve **repos** with the same logic as `/open-multirepo` (explicit list vs descriptive vs `all`/`*`/省略 vs default = full MCP scope).
2. Resolve **tag/branch hint**: pattern-match the argument against `v\d+\.\d+\.\d+`, `#\d+`, or a slash-bearing branch name; pass through verbatim into the prompt. If no hint, drop the line.
3. Resolve **extra notes**: any leading argument that is not a repo list and not a tag/branch hint goes into the `追記:` block.
4. Assemble the prompt, `encodeURIComponent` it, build the URL exactly like `/open-multirepo`.
5. Output the same shape as `/open-multirepo`:
   - `### 🚀 [pair-flow smoke test (<hint>)](<url>)`
   - bulleted attached repos
   - fenced code block with the raw prompt body

Do NOT post the link anywhere automatically. Do NOT spawn the session yourself — the user clicks the link.

## Example (default, no args)

User: `/open-multirepo-smoke`

````markdown
### 🚀 [pair-flow smoke test (latest)](https://claude.ai/code?repositories=<full-MCP-scope>&prompt=<encoded>)

**Attached repos:**
- ippoan/cc-relay
- ippoan/auth-worker
- ippoan/ci-workflows
- ippoan/claude-md
- ippoan/mcp-relay-rs
- ippoan/ci-dashboard
- yhonda-ohishi/claude-skills
- yhonda-ohishi/claude-hooks

**Prompt:**
```
github-mcp-server-rs 1-click pair flow (元 ippoan/github-mcp-server-rs#42 archived; 現行 mcp-relay-rs) の smoke test を CCoW container で実行する。
…(canned skeleton, no tag pin line)…
```
````

## Example (tag pin)

User: `/open-multirepo-smoke v0.0.15`

The prompt's `target binary` line becomes `target binary: v0.0.15 (set $GITHUB_MCP_PIN_TAG=v0.0.15 before the hook fires)`.

## Example (PR branch)

User: `/open-multirepo-smoke #50`

The prompt's `target binary` line becomes `target binary: PR #50 head (build from branch claude/implement-pair-subcommand-lSOf7 inside the new session, or pin the next release after merge)`.

## Why a sibling skill, not arguments to `/open-multirepo`

`/open-multirepo` is a generic URL builder — its value is in not assuming what the new session is for. The pair-flow smoke test is one specific recurring task with a long canned prompt and a stable acceptance checklist that would bloat `/open-multirepo` if inlined. Splitting it keeps the parent skill general-purpose and gives the smoke test a dedicated, discoverable name.

If a future smoke test for a different epic (e.g. admin elevate, or 30-day auto-pair) is needed, add a separate `/open-multirepo-<topic>-smoke` skill rather than parameterising this one.
