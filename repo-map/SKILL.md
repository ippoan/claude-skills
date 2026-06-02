---
name: repo-map
description: 1 つの repo の構造ナビゲーション skill (`<repo>-map`) を作る/更新するためのメタ skill。session-start-skill-coverage hook が「この repo に対応 skill が無い」と警告した時、または既存 map が `generated-from` 鮮度警告で古いと出た時に使う。ローカル ctags (全 repo 3.8 秒・単体 0.3 秒) + ディレクトリ/CLAUDE.md 調査で「どこに何があるか」を 1 枚にまとめ、frontmatter に `generated-from: <repo>:<tree-sha>` を付けて以後の鮮度追跡を可能にする。トリガー: 「repo map 作成」「構造 skill 作って」「skill coverage 警告」「<repo> の地図」「map 更新」「generated-from 付ける」「repo-map」等。
---

# repo-map — per-repo 構造 map skill を作る/更新する

`session-start-skill-coverage` hook が次のどちらかを警告したら、このメタ skill の
手順で `<repo>-map` skill を作る/更新する:

- **coverage**: 「対応 skill が無い repo: …」 → 新規作成
- **staleness**: 「code に追従してない skill の対象 repo: …」 → 既存 map を再生成

> 思想 (`cross-repo-symbol-index` skill 参照): 横断 symbol index を D1/CI で保存
> するのは過剰。symbol はその場でローカル ctags、手書き map skill が code と
> 乖離してないかだけ hook で見る。この skill はその map を作る側。

## 手順

### 1. tree-sha を取る (generated-from 用)

```bash
cd /home/user/<repo>
git rev-parse 'HEAD^{tree}'   # ← generated-from に入れる値
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
generated-from: <repo>:<手順1の tree-sha>
description: <repo> (...) の構造ナビゲーション。... トリガー: 「<repo>」「<主要キーワード>」...等。
---
```

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
- **generated-from 必須**: これが無いと coverage hook が「skill 無し」と見なし続ける。
- **更新 = tree-sha 更新**: staleness 警告が出たら、構造を見直して `generated-from` の
  tree-sha を現在値に更新する。

## 関連

- `cross-repo-symbol-index` — この運用全体の設計と結論 (なぜ保存せずローカル ctags か)
- `auth-worker-map` — 第一号の実例 (雛形)
- `ippoan-infra-map` — 手書きの基盤 5 repo マップ (これにも generated-from を足すと鮮度追跡できる)
- `smart-read` — file 全体でなく symbol 単位でローカル抽出
