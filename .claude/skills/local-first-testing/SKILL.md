---
name: local-first-testing
description: "org 共通テスト方針 (ippoan/claude-md#102) の実装レシピ。新しいテスト基盤・mock DB・seed スクリプト・golden テストを作る時に読む。3層構成: (1) 共有 fixture + golden テスト (2) 本番同種エミュレータ + seed (wrangler dev local / docker-compose+migrate) (3) fixture→test→local目視→PR フロー。トリガー:「テスト基盤」「mock DB」「sqlite でテスト」「seed スクリプト」「golden テスト」「fixture 使い回し」「local でテストしてから PR」「テストデータ共有」等。"
---

# local-first-testing — 共有 fixture + golden + 本番同種エミュレータ seed

org 規範 (claude-md `user-memory.md` の「Local-first testing」、Refs
ippoan/claude-md#102) の実装レシピ。**規範の要点は user-memory が正** — ここには
具体的な作り方・backend 別手順・アンチパターンを置く。

発端は ohishi-exp/nuxt-dtako-admin#268 (最低賃金チェック/給与比較の責務分離)。
worked example は同 repo の docs/plan-268-wage-tab-separation.md。

## 3層構成

### Layer 1 — 共有 fixture + golden テスト

- `tests/fixtures/<feature>/` に**入力だけ**を静的ファイルで置く (JSON / CSV /
  SQL)。ページ内・テスト内にインラインで mock データを抱えない。
- 期待値は**手計算しない**。本物の関数を通した出力を golden ファイルとして
  コミットする (reference: nuxt-dtako-admin `tests/utils/tariff-golden.test.ts`)。
  ロジック変更は golden の diff として PR に現れ、レビューで意図的か判断する。
- 同じ入力を複数の観点 (別タブ・別 API) で計算する機能は、**全観点のテストが
  同一 fixture を import** する。入力の食い違いによる観点間の数字ズレを構造で防ぐ。

golden 更新の作法: 意図したロジック変更なら golden を再生成して同 PR に含め、
PR 本文で「何が・なぜ変わったか」を説明する。テストを通すためだけの golden
上書きはしない (user-memory「Never disable/skip a test just to make CI green」)。

### Layer 2 — ローカル環境 = 本番同種エミュレータ + seed

**本番ストレージと同じ形状のまま**ローカルに再現する。独自 mock DB スキーマや
変換層を発明しない (乖離した mock は「テストは通るが本番で壊れる」を作る)。

| backend | エミュレータ | seed |
|---|---|---|
| Cloudflare Workers (R2/D1/KV/DO) | `wrangler dev` local — `.wrangler/state` に永続化 (miniflare の sqlite バックエンド。「sqlite で使い回し」はこれで満たす) | `npm run seed:local` スクリプトが Layer 1 の fixture を PUT (R2 は worker 経由 or `wrangler r2 object put --local`、D1 は `wrangler d1 execute --local --file`) |
| Postgres (Rust/SQLx 等) | docker-compose + 本物の migrate | `seed.sql` を entrypoint 依存チェーンで投入 (reference: nuxt-dtako-admin `docker-compose.test.yml` の test-db→api-migrate→db-seed、rust-alc-api 方式) |
| Supabase + SQLx | `migrate-test` skill (ローカル Postgres + splinter lint) | 同上 |

- seed スクリプトは **Layer 1 と同一の fixture を読む**。テスト用と目視用で
  データを二重管理しない。
- `.wrangler/state` / tmpfs の DB は使い捨て。壊れたら消して seed し直す。
  fixture が repo にある限りいつでも再現できる。

### Layer 3 — フロー

```
fixture 追加/変更 → vitest (unit/golden) green → seed してローカル目視 → PR
```

- CI は既存の vitest がそのまま golden を検証する (追加インフラ不要)。
- ローカル目視は Nuxt dev をローカル worker / DB に向けて行う
  (`.claude/launch.json` + preview_start)。

## 計算ロジック側の前提 (Layer 0)

fixture/golden が効くのは計算・変換ロジックが **pure function (I/O なし)** に
隔離されている場合だけ。fetch や DB アクセスが混ざったロジックはまず分離する。
UI に一時的な mock 生成コードを書く場合も、必ず本物の関数を通して生成し
(手計算の数字を並べない)、fixture へ移設したら削除する。

## アンチパターン

- ❌ 期待値の手計算・ハードコード — ロジック変更に追従できず不整合が腐る
- ❌ 本番ストレージ形状と乖離した独自 mock DB スキーマ + 変換層
- ❌ unit テスト用とローカル目視用でテストデータを別管理
- ❌ ページ/コンポーネント内にインラインの DEV mock データを恒久放置
- ❌ golden をテストを通すためだけに無説明で上書き

## 実測 gotcha (nuxt-dtako-admin#268 PR #270/#271 で確定)

Nuxt app + Cloudflare Workers 同居 repo で fixture/golden を組んだときに実際に
踏んだ罠。同型の repo (nuxt-* + workers/) では最初からこの形にする。

- **app (Nuxt) から worker src を import しない** — vue が worker の定数 1 つを
  import しただけで、worker のモジュールグラフ全体が Nuxt の厳格 tsconfig
  (noUncheckedIndexedAccess 相当) で型検査され、worker 側 tsc では通っていた
  ファイルが CI Type Check で大量エラーになる。UI が worker 側の計算値・設定値を
  必要とするなら、**worker が API レスポンス (report) に含めて返す**。理論値の
  計算が worker 1 箇所に集約され、タブ/画面間の値の一貫性も構造的に保証される
  副次効果もある。型は view 側 mirror interface (型のみの手書き複製) で受ける。
- **worker の tsconfig に node 型を足さない** — `@types/node` は
  `@cloudflare/workers-types` とグローバルが衝突する。fixture の読み込みは
  `resolveJsonModule: true` + JSON static import で行い、golden の**書き込み**
  (UPDATE_GOLDEN) だけ非リテラル指定子の動的 import
  (`await import(/* @vite-ignore */ 'node' + ':fs')`) で型解決を回避する
  (vitest は node 環境なので実行時は素の import になる)。
- **happy-dom 環境では `import.meta.url` が file: URL にならない** — root
  (Nuxt) 側テストで `readFileSync(new URL(..., import.meta.url))` は
  「The URL must be of scheme file」で落ちる。テキスト fixture (CSV 等) は
  Vite の **`?raw` import** で読む (node env でも happy-dom でも動く)。
- **root node_modules が無い環境で pure テストだけ回す** — private registry
  (@ippoan) で root install できないローカルでも、worker の vitest バイナリ +
  アドホック config (`root: '../..'`, `environment: 'node'`, include を対象
  ファイルに限定) で app/utils の pure テストを実行できる。config は worker
  ディレクトリに置く (root に置くと 'vitest' 自体が解決できない)。root
  tsconfig が `./.nuxt/tsconfig.json` を extends している repo は
  `.nuxt/tsconfig.json` に `{}` スタブが必要 (gitignore 済み領域)。
  コミットせず使い捨てる。

## 関連 skill

- `nuxt-vitest` / `worker-vitest` — テストハーネスの土台
- `coverage-check` / `coverage-test-patterns` — カバレッジゲート
- `migrate-test` — Supabase+SQLx のマイグレーション検証 (Layer 2 の一実装)
