---
name: ippoan-infra-map
generated-from: claude-md:d748a0180d1603a57ce1ce3101e404b4f9fc0a31 claude-hooks:92009eca40a94de10b98166d6e7c51e71a67d65e mcp-relay-rs:732e20f03163e776e6a21c754d020cf81d4e16b0 cc-relay:1988d9032870ca232d9917d976a11230a93b16e6 mcp-cf-workers:b077c0c01de1d93127e2f5618798faf697c3caca
description: ippoan の Claude Code on the Web (CCoW) 基盤を構成する 5 repo (claude-md / claude-hooks / mcp-relay-rs / cc-relay / mcp-cf-workers) の構造・役割・関係性を 1 枚にまとめた situational reference。どの repo に何を追加すべきか、repo 間の依存方向を即答するための地図。トリガー:「ippoan 基盤」「Claude Code 基盤」「CCoW 基盤」「5 repo 構造」「全体像」「architecture / アーキテクチャ」「cc-relay と mcp-relay-rs の違い」「どの repo に追加すべき」「claude-md と claude-hooks どっちに書く」「MCP server 全体像」「MCP 基盤マップ」「infra map」「ippoan-infra-map」等。
---

# ippoan CCoW 基盤マップ (5 repo)

ippoan の Claude Code on the Web (CCoW) 基盤は次の 5 repo で構成される。各 repo を
毎回読み直さずに、役割・依存方向・「どこに足すか」を即断するための地図。

> 出典は各 repo の実ファイル (README / Cargo.toml / package.json / `.claude/install.sh`
> / hook script)。細部 (env var の正確値・行数) は repo 側が正、ここは構造の索引。

## 1. 全体像 (CCoW 起動フロー)

```
CCoW container 起動 (web / mobile / GitHub Action から)
   │
   │  Setup script:  curl …/ippoan/claude-md/main/.claude/install.sh | bash
   ▼
┌──────────────────────────────────────────────────────────────┐
│ ① claude-md  — user-level bootstrap (Bash + Markdown)         │
│    settings.json / user-memory / hooks / MCP 登録 / clone     │
└──────────────────────────────────────────────────────────────┘
   │ install.sh が以下を派生セットアップ
   ├─▶ ② claude-hooks   …  ~/.claude/hooks/ に hook 群を配置 (guard rail)
   │                       └─▶ yhonda-ohishi/claude-skills を ~/.claude/skills/ に symlink
   ├─▶ ③ mcp-relay-rs   …  2 binary を ~/.claude.json mcpServers に登録
   │                       (github-mcp-server-rs / ref-files-mcp-server-rs)
   ├─▶ ④ cc-relay        …  /home/user/cc-relay に clone + .mcp.json を merge
   │                       (HTTP relay: mcp(-staging).ippoan.org/mcp)
   └─    ⑤ mcp-cf-workers …  ★起動 flow には乗らない (consumer repo が lib import)

Runtime (session 中):
   claude-hooks  ── PreToolUse / PostToolUse / SessionStart で git/deploy/PR を guard
   mcp-relay-rs  ── GitHub API / 参照ファイル取得を MCP tool として提供
   cc-relay      ── GitHub Issue を broker に agent 間メッセージング / shared plan
```

## 2. 各 repo の役割表

| # | repo | 言語 / runtime | レイヤ | 役割 (1 文) | 主要ファイル |
|---|------|----------------|--------|-------------|--------------|
| ① | **claude-md** | Bash + Markdown | bootstrap | CCoW 起動時の user-level 初期化と共通 CLAUDE.md template 配布 | `.claude/install.sh`, `.claude/settings.json.template`, `.claude/hooks/session-start-*.sh`, `CLAUDE.md.template` |
| ② | **claude-hooks** | Bash | guard rail | PreToolUse/PostToolUse/SessionStart hook で git/deploy/branch/PR を強制 | `install.sh`, `*-guard.sh` (bash-edit/branch-switch/deploy/pr-create…), `post-*-check.sh`, `session-start-install-skills.sh` |
| ③ | **mcp-relay-rs** | Rust (workspace) | MCP binary | GitHub API + 参照ファイル取得の MCP server 2 本 + 共有 crate | `crates/mcp-relay/`, `binaries/github-mcp-server-rs/`, `binaries/ref-files-mcp-server-rs/`, `Cargo.toml` |
| ④ | **cc-relay** | Rust (workspace) | broker | GitHub Issue を介した複数 agent 間メッセージング / 共有 task plan | `crates/agent-{core,broker,mcp,cli}/`, `.mcp.json` |
| ⑤ | **mcp-cf-workers** | TypeScript / CF Workers | SDK (lib) | CF Workers 上に MCP server を建てる薄い wrapper (stateless/stateful) | `src/index.ts` (`createWorkerMcp`), `src/durable.ts` (`createDurableMcp`), `src/auth/cf-access*.ts` |

**③ vs ④ の違い** (よく混同):
- **mcp-relay-rs** = MCP の *中身* (GitHub 操作 / file 取得 という tool を実装した binary)。
- **cc-relay** = agent 同士を *繋ぐ* broker (Issue ベースの通知・plan 共有)。tool の中身ではなく調整役。
- どちらも Rust workspace で `mcp(-staging).ippoan.org/mcp` の HTTP relay 上で multiplex される。

## 3. 関係性マトリクス (from → to)

| from | to | 参照方式 / 内容 |
|------|------|----------------|
| claude-md | claude-hooks | `install.sh` / SessionStart hook が hook 群を `~/.claude/hooks/` に配置 |
| claude-md | mcp-relay-rs | `install.sh` が 2 binary を `~/.claude.json` の `mcpServers` に登録 |
| claude-md | cc-relay | `install.sh` が `/home/user/cc-relay` に shallow clone + `.mcp.json` を merge |
| claude-md | claude-skills (yhonda-ohishi) | hook 経由で `~/.claude/sources/` に clone |
| claude-hooks | claude-skills | `session-start-install-skills.sh` が `SKILL.md` → `~/.claude/skills/<name>` に symlink |
| cc-relay | mcp-relay-rs | `.mcp.json` の HTTP relay が同 endpoint で binary へ multiplex (frame schema 共存) |
| mcp-cf-workers | (consumer: auth-worker / secrets-inventory / ci-dashboard 等) | `@ippoan/mcp-cf-workers` を npm import して各 Worker で MCP server 実装 |

要点:
- **claude-md がハブ** — 他 4 repo は claude-md の `install.sh` から派生してくる。
- **mcp-cf-workers だけ起動 flow の外** — bootstrap では触らない。MCP server を *Workers 上に新規に建てる時* に lib として import する独立した SDK。

## 4. 判断フロー:「○○を追加したい、どの repo か」

```
追加したいもの
├─ session 起動時の初期化 / settings.json allow list / CLAUDE.md 共通文言
│      → ① claude-md  (install.sh / settings.json.template / CLAUDE.md.template)
│
├─ 「この操作を禁止/検証したい」= git/deploy/PR/branch のガードレール
│      → ② claude-hooks  (PreToolUse/PostToolUse hook を 1 本足す)
│        ※ hook を settings.json に登録する側の template は ① claude-md
│
├─ GitHub 操作 / 参照ファイル取得など MCP tool の中身そのもの
│      → ③ mcp-relay-rs  (該当 binary crate に tool を追加)
│
├─ agent 間の通知 / 共有 plan / Issue ベースの調整ロジック
│      → ④ cc-relay  (agent-mcp に tool / agent-broker に broker ロジック)
│
├─ CF Workers 上で新しい MCP server を建てる共通部品
│      → ⑤ mcp-cf-workers  (src/ に factory / auth helper)
│
└─ 「skill」を足したい (この repo: claude-skills)
       → .claude/skills/<name>/SKILL.md  (新規は .claude/skills/ 配下が推奨)
```

### claude-md と claude-hooks、どっちに書く?

| 書きたいもの | repo |
|--------------|------|
| hook の **中身** (guard ロジック本体の `.sh`) | **claude-hooks** |
| hook を **登録する** settings.json template / 配置する install.sh | **claude-md** |
| repo 共通の CLAUDE.md 文言 / policy reminder | **claude-md** (`CLAUDE.md.template`) |
| branch 命名・worktree・PR の検証 reflex | **claude-hooks** (`*-guard.sh`) |

判断軸: 「**動作 (script の実体)** は claude-hooks、**配線 (どう登録・配置するか)** は claude-md」。

## 5. 関連メモ

- **policy は project memory (各 repo の `CLAUDE.md` = `CLAUDE.md.template` 派生) に書く** —
  auto-merge / `Refs #N` / branch protection 等。user memory には書かない (project memory が優先)。
- **`Closes/Fixes/Resolves #N` は使わない** → `Refs #N` / `Related to #N` (auto-close 事故回避)。
- **PR 作成直後に auto-merge を enable しない** (user の明示指示時のみ)。
- これらの reflex の出所は claude-md の `session-start-policy-reminder.sh` と `CLAUDE.md.template`。
