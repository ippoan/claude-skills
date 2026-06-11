---
title: knowledge 保存先の選定 (外部 DB 棄却 → skills に同居)
date: 2026-06-11
status: active
tags: [ccow, knowledge, search]
repo: claude-skills
issue: 58
---

## Summary

設計判断・却下案・調査結果を CCoW セッション跨ぎで参照可能にする保存先として、
外部 DB 各案 (Notion 3.5 Workers / D1+FTS5 / Vectorize / R2 SQL / ctags 索引) を
すべて棄却し、**本リポジトリ (claude-skills) に grep 可能な markdown として同居**
させる方式を採用した。理由は CCoW の標準検索がローカル grep であること。

## Context

- 判断の経緯・却下案・調査結果がチャット履歴 / GitHub Issue / 記憶に分散し、
  CCoW セッションを跨いで参照できなかった。
- CCoW の隔離コンテナはセッションごとに ephemeral。検索の標準手段はアタッチ
  された repo / スキルに対する**ローカル grep** であり、外部の索引・API には
  Claude が自発的にアクセスしない (= 置いても素通りされる)。
- 本リポジトリは既にスキルマウント経由で全文 grep の対象になっており、ここに
  knowledge を置けば索引・API・認証が一切不要になる。

## Decision

`claude-skills` に `knowledge/` を新設し、`decisions/` (経緯・過去形) と
`standards/` (規範・現在形・結論のみ) の二層で蓄える。規約は `rules.json` で
定義し、`scripts/check.py` (PR2) が CI で機械検証する。map (`<repo>-map`) は
knowledge とは別物としてコードと同じ repo へ同居移行する (Refs #59)。

## Rejected alternatives

- **Notion (3.5 Workers 経由)** — 外部 API。CCoW のローカル grep に乗らず Claude が
  自発参照しない。認証・レート制限の運用負担も増える。
- **D1 + FTS5** — 全文検索 DB を持てるが、上と同じく「grep に乗らない」ため
  セッション中に引かれない。スキーマ / migration / バインディングの保守も発生。
- **Vectorize (ベクトル検索)** — 意味検索は魅力的だが embedding パイプライン +
  外部 query が必要で、ローカル grep の即時性・ゼロ依存に劣る。
- **R2 + SQL** — オブジェクトストレージ上の構造化クエリ。索引と取得経路を自前で
  組む必要があり、過剰。
- **ctags による横断 index の永続化** — symbol 索引は「その場でローカル ctags
  (全 repo 数秒)」で足り、永続保存は stale 化するだけと結論済み
  (cross-repo-symbol-index skill 参照)。knowledge は symbol ではなく散文の判断
  記録なので ctags の対象ですらない。
