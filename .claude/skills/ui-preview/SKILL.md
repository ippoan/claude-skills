---
name: ui-preview
description: >
  ビルド済み静的 UI 成果物 (html/css/js) を ui-preview の Durable Object
  (https://ui-preview.ippoan.org) へ publish し、人間が sandbox iframe で目視確認する
  ための preview URL を発行するスキル。tsx/React/Vue/Nuxt 等を SSR/ビルドして出来た
  成果物を「見た目だけ人間に見せたい」時に使う。tar.gz を DO へ直 PUT し latest URL を
  返す (MCP: create_preview / get_preview_stats、または直 curl PUT)。
  ユーザーが「UI をプレビューして」「見た目を確認したい」「この画面どう見える？」
  「tsx の見た目」「デザイン確認」「プレビュー URL 出して」「ui-preview」「preview 配信」
  「成果物を見せて」等と言ったら、明示的に "ui-preview" と言わなくても積極的に使う。
  (ローカルで dev server を立てて screenshot する webapp-testing/cdp-browser とは別物:
   こちらは成果物を共有 URL 化して人間に渡す用途。)
---

# ui-preview

CCoW / 手書きで作った UI を、人間が **目視で確認** するための静的プレビュー配信。
成果物を tar.gz 1 本にまとめて Durable Object へ直接 PUT し、別オリジン (sandbox
iframe で opaque origin 化) で配信する。検証は自動アサーションではなく「見た目を
人間が見る」で十分、という用途に特化している。

- worker: `https://ui-preview.ippoan.org`  (repo: `ippoan/ui-preview`)
- MCP: `https://ui-preview.ippoan.org/mcp`

## いつ使うか

- tsx / React / Vue / Nuxt 等を **SSR / ビルドした静的成果物** を人間に見せたい
- 「この画面どう見える？」を URL 一本で共有したい (screenshot より実物が良い時)
- 同じ画面を直しながら何度も見てもらいたい (latest URL を開きっぱなしで reload)

ローカルで動かして screenshot を撮るだけなら `webapp-testing` / `cdp-browser` の方が
速い。ui-preview は **成果物を共有 URL 化** するのが主目的。

## 全体フロー

```
tsx → SSR/ビルド (← framework 依存。呼び出し側で ./dist 等に出す)
     → tar.gz → DO へ直 PUT (/p/new or /p/{session})
     → 応答の latest_url を取得
     → 親ページ https://ui-preview.ippoan.org/?session=<id> を人間が開く
       (sandbox iframe で表示) → 目視確認 → 直したら再 PUT → reload
```

tar 本体は **MCP (JSON) を経由させない**。base64 で content を MCP に乗せると token を
大量消費するため、DO へ直 PUT する (これが本基盤の設計原則)。

## 手順

### 1. 静的成果物を用意する

framework のビルド/SSR で `./dist` 等に `index.html` + assets を出す (呼び出し側の責務)。
例: Vite/Nuxt の `build`、React なら `renderToStaticMarkup` の出力を書き出す等。

### 2. publish する (どれか 1 つ)

**A. 直 curl (最も可搬。repo を clone してなくても使える) — 推奨**

```sh
tar -czf /tmp/preview.tgz -C ./dist .
curl -sS -X PUT --data-binary @/tmp/preview.tgz \
  https://ui-preview.ippoan.org/p/new
# 応答 JSON: { session, hash, file_count, size_bytes, over_limit, preview_url, latest_url }
```

`latest_url` を人間に渡す。`session` を控えておけば次回から同じ session に追記できる。

**B. MCP tool (`create_preview` → 直 PUT)**

MCP server (`https://ui-preview.ippoan.org/mcp`) が attach されている時。tool 名は
実際には UUID prefix が付く (`mcp__<uuid>__create_preview`)。schema は ToolSearch で
`create_preview` を query すれば引ける。

1. `create_preview()` を呼ぶ → `{ session, upload_url, latest_url, stats_url }`
2. `upload_url` に tar.gz を直 PUT (上と同じ curl)。応答に hash 等が返る。
   - `create_preview({ session })` に既存 session を渡せばそこへ追記。

**C. ui-preview repo の同梱スクリプト** (repo を clone している時)

```sh
UI_PREVIEW_BASE=https://ui-preview.ippoan.org \
  npm run publish-preview -- ./dist [--session <id>] [--dry-run]
# stdout に latest_url。--dry-run は tar の中身確認のみ (PUT しない)。
```

### 3. 人間に見てもらう

親ページを開いて渡す (sandbox iframe で latest を表示):

```
https://ui-preview.ippoan.org/?session=<session>
```

`latest_url` (`https://ui-preview.ippoan.org/p/<session>/latest/`) を直接開いても良いが、
親ページ経由だと `sandbox="allow-scripts"` (allow-same-origin なし) の iframe で
opaque origin 隔離されて読み込まれる (cookie/storage に触れない)。

### 4. 直して再 publish

同じ `session` へ再 PUT すると新しい版が追加され latest が張り替わる。人間は latest を
開きっぱなしで **reload するだけ**。hash 単位の不変 URL (`/p/<session>/<hash>/`) は
積極キャッシュ、`latest` は `no-store` で stale しない。

## メトリクス / 肥大チェック

session が膨らんできたら状態と改善提案を取れる:

```sh
curl -sS https://ui-preview.ippoan.org/p/<session>/stats
# { status: ok|warn|critical, suggestions: [...], version_count, total_bytes, image_ratio, ... }
```

MCP なら `get_preview_stats(session)`。`suggestions[]` は
`session_over_limit` (古い版を掃除) / `image_offload` (画像を R2 へ) /
`prune_versions` (latest 以外を TTL 削除) を閾値判定で返すので、そのまま人間向けの
提案文に使える。

## 注意

- 配信オリジンは認証 cookie / 秘密 binding を一切持たない。**秘密情報を含む画面を
  publish しない** (URL を知る誰でも見られる)。
- tar 上限は既定 25 MiB。超過は PUT が 413。画像が重いなら stats の `image_offload`
  提案に従う。
- `index.html` を成果物のルートに置くこと (`/p/<session>/latest/` が index を返す)。
- 展開ガードにより `../` / 絶対パス / symlink を含む tar は 422 で拒否される。
