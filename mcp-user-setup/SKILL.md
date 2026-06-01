---
name: mcp-user-setup
description: >
  Cloudflare Worker-native MCP server (ref-files-worker `/mcp` 等) を
  `~/.claude.json` の user-scope `.mcpServers` に手動で attach するスキル。
  CCoW container では `session-start-write-mcp-user-scope.sh` hook が自動で
  実行するが、ローカル dev / 別環境 / hook が skip された時の手動 fallback。
  公式 doc が薦める user-scope パターン (全 repo 共通の安定サーバ) の実装例。
  トリガー: 「ref-files-native attach」「~/.claude.json 編集」「worker MCP 手動登録」
  「claude mcp add user scope」「user-scope MCP」「MCP attach 手動」「mcp-user-setup」等。
---

# mcp-user-setup

`ippoan/ref-files-worker` の native `/mcp` を Claude Code に **user scope**
で attach する手順。CCoW container では `session-start-write-mcp-user-scope.sh`
hook ([claude-hooks](https://github.com/ippoan/claude-hooks)) が
SessionStart で自動実行するため、通常このスキルは不要。

このスキルが要る場面:

- **ローカル dev**: CCoW 外で Claude Code CLI を直に使っている時
- **hook が skip された**: token cache 期限切れ / 不在で
  `session-start-write-mcp-user-scope.sh` が skipped を返している
- **別の worker MCP を attach したい**: 例えば自作の `<custom>-worker.example.com/mcp`

## なぜ user scope か

公式 doc + 2026 community consensus:

| scope | 場所 | 用途 |
|---|---|---|
| **user** | `~/.claude.json` `.mcpServers` | **全 repo 共通の安定サーバ** (GitHub / Slack / filesystem 系) ← ref-files はこれ |
| project | `<repo>/.mcp.json` | team で共有する project-specific (DB conn 等)。**committed されるので secret 不可** |
| local | `~/.claude.json` の project path 別 entry | 個人の project 限定 |

ref-files のような「全 repo 共通の安定 filesystem-like service」は user scope が正解。

## 手順 (CLI 方式)

`claude mcp add` で 1 コマンド:

```bash
# 1. MCP-JWT を環境変数に入れる (token cache 経由 or 手動)
export REF_FILES_MCP_JWT="$(jq -r .access_token ~/.config/ref-files-mcp-server-rs/token-staging.json)"

# 2. user scope で HTTP transport + Bearer header を追加
claude mcp add \
  --transport http \
  --scope user \
  --header "Authorization: Bearer ${REF_FILES_MCP_JWT}" \
  ref-files-native \
  https://ref-files.ippoan.org/mcp
```

これで `~/.claude.json` `.mcpServers.ref-files-native` に entry が生える。
次に Claude Code を起動すると `mcp__ref-files-native__*` で tool が見える
(`folder_download_url`, `folder_list`, `file_get` 等)。

## 手順 (jq 直編集)

CLI が無い / scripted 化したい場合:

```bash
TOKEN="$(jq -r .access_token ~/.config/ref-files-mcp-server-rs/token-staging.json)"
[ -f ~/.claude.json ] || echo '{}' > ~/.claude.json
tmp=~/.claude.json.tmp.$$
jq --arg auth "Bearer $TOKEN" '
  .mcpServers //= {} |
  .mcpServers["ref-files-native"] = {
    type: "http",
    url: "https://ref-files.ippoan.org/mcp",
    headers: { Authorization: $auth }
  }
' ~/.claude.json > "$tmp" && mv "$tmp" ~/.claude.json
chmod 600 ~/.claude.json
```

idempotent — 既存 entries は破壊されない。

## 期限切れの token を refresh

`access_token` は HS256 JWT (typically 24h 有効)。期限切れたら token cache
を再 hydrate:

- **CCoW**: `session-start-install-mcp-relay.sh` が auth-worker `/mcp/pair/grant-via-oat` 経由で再取得
- **ローカル**: `install-mcp-ref-files.sh` を再実行 (pair flow が必要なら 1-click)

token cache が更新されたら、上記スクリプトを再実行して `.mcpServers.ref-files-native.headers.Authorization` を上書き。

## 削除

`claude mcp remove ref-files-native --scope user`、または jq で:

```bash
jq 'del(.mcpServers["ref-files-native"])' ~/.claude.json > tmp && mv tmp ~/.claude.json
```

## トラブルシュート

| 症状 | 原因 | 対処 |
|---|---|---|
| Claude Code 起動時 `failed` status | `Authorization` header 不正 (token expired) | token cache を refresh して再登録 |
| `tools/list` に出ない | `.mcpServers.ref-files-native.type` が `"http"` でない | jq で type 確認 (`streamable-http` alias でも OK) |
| URL に到達しない | worker `/mcp` が 404 | `curl -I https://ref-files.ippoan.org/mcp` で疎通確認 |
| 401 Unauthorized | aud claim 不一致 | worker の `MCP_JWT_AUDIENCE` を確認 (`"*"` 設定済なら aud 不問、Refs ippoan/ref-files-worker#27) |

## 関連

- 自動化 hook: `ippoan/claude-hooks/session-start-write-mcp-user-scope.sh`
  (PR ippoan/claude-hooks#5)
- worker `/mcp` 実装: ippoan/ref-files-worker#23 (Phase) / #29 (folder_download_url)
- 公式 docs: https://code.claude.com/docs/en/mcp
