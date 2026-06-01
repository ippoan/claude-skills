---
name: ref-files-bulk
description: >
  ref-files MCP の `folder_download_url` で folder 配下を tar.gz で一括取得して
  `/tmp/` に展開するスキル。`file_get` を 1 ファイルずつ呼ぶと content_base64
  で大量の token を消費するため、spec 一式・往復メール・複数 markdown など
  folder 単位で読みたい時はこちらを優先する。
  トリガー: 「ref-files から spec を読む」「往復メールを読む」「folder ごと参照」
  「複数 file 取得」「file_get で token 食う」「spec/ 配下を全部見たい」
  「egov-shinsei-sdk-spec から取得」「ref-files bulk」「tar.gz でおろす」等。
---

# ref-files-bulk

ref-files MCP server (`ippoan/ref-files-worker`) の `folder_download_url` tool
で folder 配下を tar.gz として一括取得し、ローカルに展開して通常の Read tool
で読むためのスキル。

## なぜ必要か

`file_get` MCP tool は file 内容を `content_base64` で返す。25KB の markdown
は base64 で ~33KB → tool result として ~33K token 消費する。spec 配下の
複数 file を読むだけで context が一気に詰まる (実害: egov-shinsei-sdk#21
セッションで照会メール 1 通読むのに ~30K token 浪費)。

`folder_download_url` は pre-signed URL を返すだけで、実体は `curl` で
取得 → `tar xzf -` で展開する。MCP の往復には URL 文字列しか乗らないので
token 消費は数百 B で済む。

## 前提

- ref-files MCP server (`/mcp` native, または `ref-files-mcp-server-rs` relay
  経由のどちらでも) が attach されている事
- tool 名は実際には UUID prefix が付く: `mcp__<uuid>__folder_download_url`
  (ToolSearch で `folder_download_url` を query すると schema が引ける)

## 手順

### 1. 取得対象の folder path を特定

`folder_list` で対象 repo の folder 構造を確認:

```
folder_list(repo_id="<uuid>", path="spec", recursive=false)
```

### 2. 一括 download URL を発行

```
folder_download_url(repo_id="<uuid>", path="spec/subdir")
```

戻り値:

```json
{
  "download_url": "https://ref-files.ippoan.org/download/<token>",
  "token": "...",
  "expires_at": "2026-06-01T...",
  "method": "GET",
  "content_type": "application/gzip"
}
```

token は 1 回 GET すると consumed (`410 Gone`)。TTL は 10 分。

### 3. bash で取得 → 展開

```bash
mkdir -p /tmp/ref-files/<topic>
curl -sSf "<download_url>" | tar xzf - -C /tmp/ref-files/<topic>
ls -la /tmp/ref-files/<topic>
```

`X-File-Count` レスポンスヘッダで件数も確認できる:

```bash
curl -sSf -D /tmp/headers.txt "<download_url>" | tar xzf - -C /tmp/ref-files/<topic>
grep X-File-Count /tmp/headers.txt
```

### 4. 通常の Read tool で読む

展開後は普通のローカル file。`Read /tmp/ref-files/<topic>/foo.md` でアクセス。
- `.eml` (メール) は MIME なので Read で開いても読めない → **eml-read** skill で
  decode (`python3 ~/.claude/skills/eml-read/scripts/eml-read.py <file.eml>`)。
- `.pdf` は pdf skill で。

## オプション: root path で repo 全体

```
folder_download_url(repo_id="<uuid>", path="")
```

repo 全体の live file を `repo.tar.gz` として download。100 ファイル超だと
worker の CPU time 制限に当たる可能性があるので、必要な subfolder に絞る方が
無難。

## 失敗パターン

| 症状 | 原因 | 対処 |
|---|---|---|
| `403 forbidden` | repo の owner_login と JWT が不一致 | 自 org の repo か確認 |
| `404 not_found reason=folder` | path 指定ミス | `folder_list` で実在確認 |
| `410 gone reason=consumed` | token を 2 回叩いた | 再発行 (`folder_download_url` を再呼出) |
| `410 gone reason=expired` | TTL (10 分) 切れ | 再発行 |
| `tar: invalid magic` | URL を curl 経由で取らずブラウザで開いた等で gzip が解凍済 | `curl` でそのまま pipe する |

## 関連

- ref-files-worker repo: `src/routes/folders.ts` (download-url issue) /
  `src/routes/uploads.ts` の `streamFolderTarGz` (stream 本体)
- 設計 issue: ippoan/ref-files-worker#28
- 実装 PR: ippoan/ref-files-worker#29
- file_get で困った発生源: ippoan/egov-shinsei-sdk#21
