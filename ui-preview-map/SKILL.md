---
name: ui-preview-map
generated-from: ui-preview:92c3bbc08e721c8ac0a7a7a746ea16f67029c8a5
description: ippoan/ui-preview (Cloudflare Workers + Durable Object、静的 UI 成果物の ephemeral プレビュー配信基盤) の構造ナビゲーション。tar.gz 直 PUT → 展開ガード → SQLite 保存 → 別オリジン配信 → WS live 更新 → TTL 削除、と control/配信オリジン分離・iframe sandbox 隔離・MCP (create_preview/get_preview_stats) の配置と gotcha を 1 枚にまとめる。トリガー:「ui-preview」「preview 配信」「PreviewDO」「create_preview」「tar.gz PUT」「展開ガード」「PREVIEW_ORIGIN」「iframe sandbox」「version TTL」「ui-preview.ippoan.org」等。
---

# ui-preview-map — ippoan/ui-preview 構造ナビゲーション

Cloudflare Workers + Durable Object ベース。**ビルド済み静的 UI 成果物 (tar.gz) を
直 PUT で受け、展開 → SQLite 保存 → 別オリジンで配信** する ephemeral プレビュー
基盤。worker entry は薄く、実体 (受信/展開/保存/配信/metrics) は `PreviewDO` 側。

> 細部 (関数シグネチャ・正確な行) は repo 側が正。ここは「どこを見るか」の索引。
> frontmatter の `generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す → その時 tree-sha を更新する。

## 区画 (CLAUDE.md の表が一次情報)

| path | 役割 |
|---|---|
| `src/index.ts` | Worker entry。session (=DO id) で振り分けて `PreviewDO` に委譲 + iframe デモ親ページ (WS live reload script 内蔵) |
| `src/do/preview-do.ts` | `PreviewDO`。受信→展開→保存→配信→stats を直列・アトミックに。Host で配信/control 判定 |
| `src/lib/tar.ts` | 最小 tar リーダ (typeflag 保持) |
| `src/lib/extract.ts` | 展開ガード 3 点 (path traversal / MIME / 特殊エントリ拒否) |
| `src/lib/blob-store.ts` | `BlobStore` 抽象 + `SqliteBlobStore` (R2 差し替えポイント) |
| `src/lib/metrics.ts` | `evaluateStats` (status / suggestions[]) |
| `src/lib/{hash,mime}.ts` | hash / MIME 判定 |
| `src/mcp/tools.ts` | MCP ツールの純粋ロジック (pool で実 DO テスト) |
| `src/mcp/server.ts` | `createWorkerMcp` 配線 (`/mcp` 到達時のみ遅延 import) |
| `src/env.ts` | binding + 閾値 (vars から数値化) |
| `scripts/publish-preview.mjs` | CCoW 側: 静的成果物 → tar.gz → DO 直 PUT → preview_url |

## entrypoint (`src/index.ts` の route)

- `GET /` — iframe デモ親ページ (`?session=<64hex>` で latest 表示、WS で live reload)
- `POST /mcp` — MCP (`create_preview` / `get_preview_stats`)。重い SDK を**遅延 import**
- `PUT /p/new` — 新規 session 採番 (`newUniqueId`) して 1 版目保存
- `PUT /p/{session}` — 既存 session に新版追加 / `GET /p/{session}/...` — 配信 / latest / stats / ws
- `GET /health`
- `export { PreviewDO }`

## gotcha (CLAUDE.md / wrangler.toml 由来)

- **control 面と配信オリジンを分離**: control = `ui-preview.ippoan.org` (custom domain)、配信 = `PREVIEW_ORIGIN` (`ui-preview.m-tama-ramu.workers.dev`)。**別オリジンにする理由**は現代 framework の `<script type="module">` が opaque origin (allow-same-origin 無し sandbox) では hydration しないため。別オリジンなら iframe を `allow-scripts allow-same-origin` にしても隔離が「別オリジンである事」で担保される。
- **`workers_dev = true` を明示**: custom domain 追加後に workers.dev preview が無効化され `error code: 1042` で配信不能になったため明示再有効化。
- **session = DO id**。デモ親ページの `?session` は **64 桁 hex のみ許可** (inline script 埋め込み XSS 対策、`jsStr` で `<` を `<` に)。
- **ephemeral**: 版は最後の publish から `VERSION_TTL_SECONDS` (既定 600=10 分) で DO alarm が削除。閾値は全て vars 上書き可 (`MAX_TAR_BYTES`=25MiB / `SESSION_SOFT_LIMIT_BYTES` / `MAX_VERSIONS` / `IMAGE_RATIO_WARN`)。
- **secret 不要**: 配信オリジンは認証 cookie / 秘密 binding を一切持たない設計。`[secrets] required = []` を明示 (ci-workflows の secret-verify が監査可能なよう)。
- **`@ippoan/mcp-cf-workers` は GitHub Packages 公開** (public でも npm read に token 要)。CI は `npm_scope: '@ippoan'` で install。

## CCoW / CI から見た立ち位置

- **`ui-preview` skill の配信基盤**。tsx/React/Vue/Nuxt 等をビルドした成果物を tar.gz で control (`https://ui-preview.ippoan.org`) へ直 PUT し、別オリジンの配信 URL を人間に渡す (iframe で目視確認)。`scripts/publish-preview.mjs` が CCoW 側の publish 経路。
- CI は `frontend-ci.yml` (project_type: worker)。

## 関連 skill

- `ui-preview` — この worker を consume して preview URL を発行する skill (一次の利用者)
- `worker-vitest` — Vitest テスト (`test/`)
- `cross-repo-symbol-index` — per-repo map の運用方針 (鮮度 hook)
