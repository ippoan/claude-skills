---
name: freee-map
generated-from: freee:c9b23144ccc139e81985df61d8af9ad8e1e8879c
description: ippoan/freee (法人会計を Claude Code + freee MCP 経由で行う薄い運用 repo。CLAUDE.md + hook scripts + .claude/skills/freee-* の skill 群) の構造ナビゲーション。MCP tool prefix の環境差 / 自動ログ hook / 勘定科目検索 / 銀行同期明細の消込制約・gotcha を 1 枚にまとめる。トリガー:「freee」「freee MCP」「勘定科目検索」「未仕訳」「消込」「自動で経理」「freee_api」「会計処理」「仕訳登録」「freee ログ」「FREEE_COMPANY_ID」等。
---

# freee-map — ippoan/freee 構造ナビゲーション

法人設立後の会計処理を **Claude Code + freee MCP** で回す薄い運用 repo。アプリ code は
無く、`CLAUDE.md` (運用ルール) + `scripts/` (hook) + `.claude/skills/freee-*` (freee 操作
skill 群) で構成される。freee API は全て MCP tool (`mcp__*__freee_api_*`) 経由で叩く。

> ここは索引 (pointer)。細部は repo 側が正。frontmatter の `generated-from` が現在の
> repo tree-sha とズレたら session-start hook が再生成を促す → その時 tree-sha を更新する。

## 区画

| 区画 | パス | 役割 |
|---|---|---|
| **運用ルール** | `CLAUDE.md` | MCP tool prefix の環境差 / 勘定科目検索 / 銀行同期明細の消込制約 / 自動ログ / TODO / 書類管理 / Windows 注意 |
| **hook scripts** | `scripts/*.py` | SessionStart / PostToolUse hook 実体 (下表)。`.claude/settings.json` から起動 |
| **hook 設定** | `.claude/settings.json` | SessionStart 3 本 + PostToolUse (matcher `mcp__freee-mcp__freee_api_*`) 2 本 |
| **freee skill 群** | `.claude/skills/freee-*/SKILL.md` | freee 操作の詳細 skill (下表) |

### scripts/ (hook 実体)

| script | hook | 役割 |
|---|---|---|
| `session_start.py` | SessionStart | `.env` 存在 + freee 認証状態 + todo.json + 前回ログサマリ |
| `backup_journals.py` | SessionStart | 仕訳帳を freee API から全件取得 → ローカル + Google Drive 同期 (token は freee MCP の tokens.json から、期限切れ自動 refresh) |
| `backup_logs.py` | SessionStart / PostToolUse | rclone で `logs/` → `gdrive:freee-logs/` 同期 |
| `log_freee_op.py` | PostToolUse | stdin の hook data を service 別フォルダに日付別 JSON 追記 (認証/取得系は skip) |

### .claude/skills/ (freee 操作 skill)

| skill | 役割 |
|---|---|
| `freee-api-skill` | freee-mcp / freee-sign-mcp の詳細 API リファレンス + recipes/ + references/ + sign-references/ (会計・人事労務・請求書・工数・販売・電子契約)。freee_jp 公式 (Apache-2.0) |
| `freee-account-search` | 勘定科目 (account_items) 検索。198 件で 156K 文字 → token 超過するため専用 python script + cache 経由 |
| `freee-unmatched-check` | 銀行/CC/現金口座の未仕訳 (消込待ち) 明細の一括確認 |

## entrypoint / 起動フロー

- code の entrypoint は無い。**SessionStart hook (`.claude/settings.json`)** が repo を開いた時に session_start / backup_journals / backup_logs を走らせるのが実質の起点。
- 以降の freee 操作は MCP tool 呼び出し → PostToolUse hook (`log_freee_op` + `backup_logs`) で自動記録。
- log は service 別: `logs/{accounting,hr,invoices,time_tracking,sales,social_insurance}/<date>.json`。

## gotcha (CLAUDE.md 由来)

- **MCP tool prefix は起動環境で変わる**: local (CLI/Desktop) = `mcp__freee-mcp__freee_api_*` / CCoW = `mcp__<connector-uuid>__freee_api_*` (例 `ac8e39b2-...`)。doc では `mcp__*__freee_api_*` とワイルドカード表記。**`.claude/settings.json` の PostToolUse matcher は `mcp__freee-mcp__freee_api_*` 固定なので、CCoW (UUID prefix) では自動ログ hook が match せず発火しない点に注意**。
- **勘定科目は直接 API を叩かず `freee-account-search` script を使う** (156K 文字で token 超過)。`--broad` でカテゴリ含む広域検索。cache は `~/.claude/projects/c--freee/freee-cache/`。
- **銀行同期済み明細は API で取引を作らない**: freee API に消込機能が無く、deals 作成時の payments が別明細を生成して重複する。銀行同期口座の仕訳は **freee Web 画面の「自動で経理」から登録**するよう user に案内する。
- 機密は `.env` (`FREEE_COMPANY_ID`、gitignore 済)。MCP では `freee_get_current_company` でも取得可。
- 書類 `docs/` (social_insurance / tax) は gitignore 済 + rclone で Google Drive backup。
- Windows 環境: python 出力は `PYTHONIOENCODING=utf-8` を付ける。bash シェル (Unix 構文)。パスは `c:/freee/...` 前提で settings.json に hard-code。

## CCoW / CI から見た立ち位置

- CI / build は無い (運用 repo)。freee MCP server への疎通は `freee_auth_status` / `freee_server_info` で確認 (参考 yhonda-ohishi/freee#1)。
- CCoW では claude.ai の custom connector 経由で `mcp.freee.co.jp/mcp` に接続 (connector UUID が tool prefix)。

## 関連 skill

- `freee-api-skill` / `freee-account-search` / `freee-unmatched-check` — repo 同梱の freee 操作 skill (上表)。本 map はそれらの索引であって個々の使い方は各 SKILL.md が正
- `repo-map` / `cross-repo-symbol-index` — この per-repo map の運用方針 (generated-from 鮮度 hook)
