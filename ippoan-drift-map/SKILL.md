---
name: ippoan-drift-map
generated-from: ippoan-drift:4b825dc642cb6eb9a060e54bf8d69288fbee4904
description: ippoan/ippoan-drift の構造ナビゲーション。現時点では commit ゼロの空 repo (初期化のみ) のためプレースホルダ。最初の commit が入ったら repo-map メタ skill で索引化する。トリガー: 「ippoan-drift」「drift repo」「ippoan-drift-map」等。
---

# ippoan-drift-map — ippoan/ippoan-drift 構造ナビゲーション (プレースホルダ)

**この repo は現在 commit ゼロの空 repo** (default branch に HEAD 無し)。索引化できる
コードがまだ無いため、本 skill は coverage hook を満たすためのプレースホルダ。

> `generated-from` の tree-sha には git の **empty tree** (`4b825dc6…`) を入れてある。
> 最初の commit が入ると `HEAD^{tree}` が empty tree と一致しなくなり、
> session-start-skill-coverage hook が「code に追従してない (要再生成)」と警告する
> → その時に `repo-map` メタ skill の手順で実際の区画・entrypoint・gotcha を索引化し、
> `generated-from` を現在の tree-sha に更新する。

## 現状

| 項目 | 値 |
|---|---|
| 状態 | 空 repo (no commits) |
| 索引 | なし (中身が無い) |
| 次のアクション | 最初の commit 後に `repo-map` で再生成 |

## 関連

- `repo-map` — この map を実体化する時の手順 (ctags + 構造調査 → 索引 → generated-from)
- `cross-repo-symbol-index` — per-repo map skill 運用の設計と鮮度 hook の方針
