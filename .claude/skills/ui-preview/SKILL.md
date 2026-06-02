---
name: ui-preview
description: >
  ビルド済み静的 UI 成果物 (html/css/js) を ui-preview の Durable Object へ publish し、
  人間が iframe で目視確認する preview URL を発行するスキル。tsx/React/Vue/Nuxt 等を
  SSR/ビルドして出来た成果物を「見た目だけ人間に見せたい」時に使う。tar.gz を control
  (https://ui-preview.ippoan.org) へ直 PUT し、別オリジンの配信 URL を返す
  (MCP: create_preview / get_preview_stats、または直 curl PUT)。親ページは WebSocket で
  publish を検知して自動更新し、版は最後の publish から 10 分で自動削除 (ephemeral)。
  ユーザーが「UI をプレビューして」「見た目を確認したい」「この画面どう見える？」
  「tsx/Nuxt の見た目」「デザイン確認」「プレビュー URL 出して」「ui-preview」「preview 配信」
  「成果物を見せて」等と言ったら、明示的に "ui-preview" と言わなくても積極的に使う。
  (ローカルで dev server を立てて screenshot する webapp-testing/cdp-browser とは別物:
   こちらは成果物を共有 URL 化して人間に渡す用途。)
---

# ui-preview

CCoW / 手書きで作った UI を、人間が **目視で確認** するための静的プレビュー配信。
成果物を tar.gz 1 本にまとめて Durable Object へ直接 PUT し、**別オリジン**で配信する。
検証は自動アサーションではなく「見た目を人間が見る」で十分、という用途に特化。

- repo: `ippoan/ui-preview`
- control 面 (publish / MCP / 親ページ / stats): `https://ui-preview.ippoan.org`
- **配信オリジン** (preview 本体): `https://ui-preview.m-tama-ramu.workers.dev`
- MCP: `https://ui-preview.ippoan.org/mcp`

## いつ使うか

- tsx / React / Vue / Nuxt 等を **SSR / ビルドした静的成果物** を人間に見せたい
- 「この画面どう見える？」を URL 一本で共有したい (screenshot より実物が良い時)
- 直しながら何度も見てもらいたい (親ページを開きっぱなし → publish で **自動更新**)

ローカルで動かして screenshot を撮るだけなら `webapp-testing` / `cdp-browser` の方が
速い。ui-preview は **成果物を共有 URL 化** するのが主目的。

## 全体フロー

```
tsx → SSR/ビルド (← framework 依存。呼び出し側で ./dist 等に出す)
     → tar.gz → control へ直 PUT (/p/new or /p/{session})
     → 応答の latest_url (配信オリジン) を取得
     → 親ページ https://ui-preview.ippoan.org/?session=<id> を人間が開く
       (別オリジンの iframe で表示) → 再 publish すると WebSocket で自動更新
```

tar 本体は **MCP (JSON) を経由させない**。base64 で content を MCP に乗せると token を
大量消費するため、control へ直 PUT する (これが本基盤の設計原則)。

## 手順

### 1. 静的成果物を用意する

framework のビルド/SSR で `./dist` 等に `index.html` + assets を出す (呼び出し側の責務)。
**SSR サーバ (`.output/server` 等) は非対応** — 静的生成 (SSG/SPA) の出力を使う。

> **Nuxt / Vite / SPA の重要注意**: 配信は `…/p/{session}/latest/` という deep path 配下。
> 既定の **絶対パス asset** (`/_nuxt/…`, `/assets/…`) は配信オリジンの root を指して 404 に
> なる。**base をその配信パスに合わせてビルド**すること:
> ```sh
> # session を先に発行 (create_preview か空 PUT) してから
> NUXT_APP_BASE_URL="/p/$SESSION/latest/" npx nuxi generate   # Nuxt
> # Vite なら vite build --base=/p/$SESSION/latest/
> ```
> (Nuxt は `app.baseURL: './'` のような相対 base を `/` に正規化するので不可。)
> 素の HTML/CSS/JS や、相対パスでビルドされた成果物はそのままで OK。

### 2. publish する (どれか 1 つ)

**A. 直 curl (最も可搬。repo を clone してなくても使える) — 推奨**

```sh
tar -czf /tmp/preview.tgz -C ./dist .
curl -sS -X PUT --data-binary @/tmp/preview.tgz \
  https://ui-preview.ippoan.org/p/new
# 応答 JSON: { session, hash, file_count, size_bytes, over_limit, preview_url, latest_url }
# preview_url / latest_url は配信オリジン (workers.dev) を指す。
```

`latest_url` を人間に渡す。`session` を控えておけば次回から同じ session に追記できる。

**B. MCP tool (`create_preview` → 直 PUT)**

MCP server (`https://ui-preview.ippoan.org/mcp`) が attach されている時。tool 名は
実際には UUID prefix が付く (`mcp__<uuid>__create_preview`)。schema は ToolSearch で
`create_preview` を query すれば引ける。Nuxt 等で session を先に確定したい時に有用:

1. `create_preview()` を呼ぶ → `{ session, upload_url, latest_url, stats_url }`
2. その `session` で base を合わせてビルド (上の Nuxt 注意参照)
3. `upload_url` に tar.gz を直 PUT。応答に hash 等が返る。
   - `create_preview({ session })` に既存 session を渡せばそこへ追記。

**C. ui-preview repo の同梱スクリプト** (repo を clone している時)

```sh
UI_PREVIEW_BASE=https://ui-preview.ippoan.org \
  npm run publish-preview -- ./dist [--session <id>] [--dry-run]
# stdout に latest_url。--dry-run は tar の中身確認のみ (PUT しない)。
```

### 3. 人間に見てもらう (ライブ更新)

親ページを開いて渡す:

```
https://ui-preview.ippoan.org/?session=<session>
```

- 親ページは **WebSocket** で control に繋ぎ、再 publish を検知して iframe を**自動更新**
  する (毎回リロード不要。ヘッダに `● live` / `↻ 更新` バッジ)。WS 不可時は 3 秒
  polling にフォールバック。
- 配信は別オリジン (workers.dev) の iframe (`allow-scripts allow-same-origin`) なので
  **module を使う現代フレームワーク (Nuxt/Vite/React) も hydration して動く**。親 DOM /
  cookie には別オリジンゆえ届かない。
- `latest_url` を直接ブラウザで開いても見られる (`https://ui-preview.m-tama-ramu.workers.dev/p/<session>/latest/`)。

### 4. 直して再 publish

同じ `session` へ再 PUT すると新版が追加され latest が張り替わり、開いている親ページが
WebSocket で自動更新される。hash 単位の不変 URL は積極キャッシュ、`latest` は stale しない。

## TTL (ephemeral) — 自動掃除

版は **最後の publish から 10 分** (`VERSION_TTL_SECONDS`、既定 600) で DO alarm が削除する。
全版が消えると session は空 (404) になる。= プレビューは使い捨て。長く残したいなら定期的に
再 publish するか、別途保存する。

## メトリクス / 肥大チェック

```sh
curl -sS https://ui-preview.ippoan.org/p/<session>/stats
# { status: ok|warn|critical, suggestions: [...], version_count, total_bytes,
#   image_ratio, ttl_seconds, ... }
```

MCP なら `get_preview_stats(session)`。`suggestions[]` は `session_over_limit` (古い版を
掃除) / `image_offload` (画像を R2 へ) / `prune_versions` (latest 以外を TTL 削除) を
閾値判定で返すので、そのまま人間向けの提案文に使える。

## 注意

- 配信オリジンは認証 cookie / 秘密 binding を一切持たない。**秘密情報を含む画面を
  publish しない** (URL を知る誰でも見られる)。
- tar 上限は既定 25 MiB。超過は PUT が 413。画像が重いなら stats の `image_offload` に従う。
- `index.html` を成果物のルートに置くこと (`/p/<session>/latest/` が index を返す)。
- 展開ガードにより `../` / 絶対パス / symlink を含む tar は 422 で拒否される。
- 親ページの `?session=` は 64 桁 hex (= DO id) のみ有効。create_preview / PUT が返す
  session をそのまま使う。
