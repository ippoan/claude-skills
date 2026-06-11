---
name: repo-map
description: 1 つの repo の構造ナビゲーション skill (`<repo>-map`) を作る/更新するためのメタ skill。session-start-skill-coverage hook が「この repo に対応 skill が無い」と警告した時、または skills-check CI (ci-workflows#118) が map の stale を warn した時に使う。ローカル ctags (全 repo 3.8 秒・単体 0.3 秒) + ディレクトリ/CLAUDE.md 調査で「どこに何があるか」を 1 枚にまとめ、frontmatter に `generated-from: <repo>:<commit-sha>` + `paths: [...]` を付けて以後の鮮度追跡を可能にする。トリガー:「repo map 作成」「構造 skill 作って」「skill coverage 警告」「<repo> の地図」「map 更新」「generated-from 付ける」「repo-map」等。
---

# repo-map — per-repo 構造 map skill を作る/更新する

`session-start-skill-coverage` hook が次のどちらかを警告したら、このメタ skill の
手順で `<repo>-map` skill を作る/更新する:

- **coverage**: 「対応 skill が無い repo: …」 (SessionStart hook) → 新規作成
- **staleness**: skills-check CI (ci-workflows#118) が「`paths` に変更があるのに
  map が同 PR で更新されていない」と warn → 既存 map を再生成

> 思想 (`cross-repo-symbol-index` skill 参照): 横断 symbol index を D1/CI で保存
> するのは過剰。symbol はその場でローカル ctags、手書き map skill が code と
> 乖離してないかだけ見る。この skill はその map を作る側。
>
> **鮮度判定の置き場 (Refs claude-hooks#18 / ci-workflows#118)**: stale 判定は
> SessionStart hook から **CI (PR diff 判定)** へ移譲された。hook は「map の無い
> attached repo の通知」だけに縮小。map は各 repo の `.claude/skills/<repo>-map/`
> へ同居移行していく (Refs claude-skills#59) ので、コードと同じ PR で更新される。

## generated-from 新形式 (commit-sha + paths)

`<repo>-map` の frontmatter は 2 フィールドで鮮度を表す:

```yaml
generated-from: <repo>:<commit-sha>   # 旧 tree-sha → commit-sha
paths: [src/, proto/]                  # map が参照する対象パス (必須)
```

- **commit-sha** (`git rev-parse HEAD`): CI が `git rev-list --count <commit>..HEAD -- <paths>`
  で**乖離距離**を測れる (tree-sha の完全一致は 1 コミットで常時 stale 化 = オオカミ少年
  だった、claude-hooks#18 の根本原因)。
- **paths**: map がカバーするコードのスコープ。**この paths 下に変更があった時だけ
  stale 扱い**。`README.md` 修正等の無関係な変更で stale にならない。
- 旧形式 (`<repo>:<tree-sha>`、paths 無し) は移行期間中 **warn のみで判定スキップ**
  (claude-hooks#18 Q1)。`repo-map` で再生成する時に新形式へ寄せる。

## 手順

### 1. commit-sha と paths を取る (generated-from 用)

```bash
cd /home/user/<repo>
git rev-parse HEAD            # ← generated-from の <commit-sha> に入れる (tree でなく commit)

# map が参照するパスを決める (entrypoint / src / proto 等、構造の主要部)
ls -d src proto crates app 2>/dev/null   # paths: [...] に入れる候補
```

### 2. ローカルで構造を把握 (速い)

```bash
# universal-ctags が無ければ入れる (1 回)
which ctags || sudo apt-get install -y --no-install-recommends universal-ctags

# symbol を一覧 (.git/依存は default 除外。name/kind/開始終了行が出る)
ctags -R --exclude=node_modules --exclude=dist --exclude=target \
  --output-format=json --fields=+ne -f /tmp/<repo>-tags.json .
wc -l /tmp/<repo>-tags.json            # symbol 数の感触

# 区画の把握
find . -maxdepth 2 -type f \( -name '*.ts' -o -name '*.rs' -o -name '*.go' \) | sort
ls src/handlers src/ crates 2>/dev/null    # グループの粒度
```

### 3. gotcha を集める

- repo の `CLAUDE.md` / `README.md` を読む (運用ルール・落とし穴の単一 SoT)
- entrypoint (`src/index.ts` / `main.rs` / `wrangler.*` の route・binding)
- env 別構成 (prod/staging)、意図的に壊してある箇所 (guardrail) 等

### 4. `claude-skills/<repo>-map/SKILL.md` を書く

frontmatter:

```yaml
---
name: <repo>-map
generated-from: <repo>:<手順1の commit-sha>
paths: [src/, proto/]
description: <repo> (...) の構造ナビゲーション。... トリガー: 「<repo>」「<主要キーワード>」...等。
---
```

> 移行先 (Refs claude-skills#59): 新規 / 再生成する map は対象 repo 側の
> `.claude/skills/<repo>-map/SKILL.md` に置くのが最終形 (コードと同じ PR で更新
> できる)。未移行の map は当面 `claude-skills/<repo>-map/` のまま。

本文は **索引** (pointer) に徹する。網羅しない (repo 側が正)。推奨セクション:

- **区画 (module グループ) の表** — グループ → 主要ファイル → 役割
- **entrypoint** — route / binding / main
- **gotcha** — 意図的な設計・落とし穴 (CLAUDE.md 由来)
- **CCoW/CI から見た立ち位置** — 誰が使う / どう deploy
- **関連 skill**

実例テンプレ: **`auth-worker-map`** skill を雛形にする。

### 5. README に 1 行追記

`README.md` の skill 一覧に `<repo>-map` を足す。

### 6. (任意) 鮮度検証

```bash
# hook が covered と認識するか: skill を ~/.claude/skills に置いて実行
bash ~/.claude/sources/claude-hooks/session-start-skill-coverage.sh 2>/dev/null \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
```

## 原則

- **lean**: 1 文/区画。詳細は repo 側。膨らんだら symbol はその場 ctags で取れば良い。
- **generated-from + paths 必須**: これが無いと coverage hook が「skill 無し」と
  見なし続け、CI も鮮度を測れない。
- **更新 = commit-sha 更新**: stale 警告が出たら、構造を見直して `generated-from` の
  commit-sha を現在の `git rev-parse HEAD` に更新する (paths が広がった/狭まった
  時は paths も直す)。

## 関連

- `cross-repo-symbol-index` — この運用全体の設計と結論 (なぜ保存せずローカル ctags か)
- `auth-worker-map` — 第一号の実例 (雛形)
- `ippoan-infra-map` — 手書きの基盤 5 repo マップ (これにも generated-from を足すと鮮度追跡できる)
- `smart-read` — file 全体でなく symbol 単位でローカル抽出
