---
name: ippoan-lib-catalog
description: ippoan/ohishi-exp org の「この機能の canonical 実装はどこか」の capability 粒度カタログ。util / helper / 横断ロジック (JWT 検証、timing-safe 比較、base64url、fetch wrapper、認証 UI、CSV パース、Cloud Run proxy skeleton、coverage script、CI pipeline 等) を新規実装する前に必ず参照し、既存 lib があれば consume する (lib-first、CLAUDE.md.template の policy)。トリガー:「再実装」「util 作る」「helper 書く」「どの lib」「lib ある?」「canonical どこ」「共通化」「lib-first」「車輪の再発明」「JWT 検証 worker」「timing-safe」「createAuthFetch」「coverage script」「lib catalog」等。
---

# ippoan-lib-catalog — capability → canonical の対応表

> **本体は knowledge へ移設しました** (Refs ippoan/claude-skills#58)。
> capability → canonical の対応表は
> [`knowledge/standards/libs/org-capability-catalog.md`](../knowledge/standards/libs/org-capability-catalog.md)
> が単一の真実です。このスキルはトリガー (description) を維持したままの**ポインタ**で、
> 内容の追加・更新は移設先で行ってください。

**使い方**: util / helper / 横断ロジックを書きたくなったら、まず移設先の表で canonical
を探す → 無ければ org 横断検索 (`grep -rn "<機能語>" /home/user/*/src`、または その場
ctags) → それでも無ければ新規実装して良いが、**2 repo 目で必要になった時点で lib
切り出しを user に提案する** (rule of two)。

```sh
grep -ri "<機能語>" knowledge/standards/libs/
```

関連 skill: `knowledge` (decisions/standards の蓄積) / `cross-repo-symbol-index`
(その場 ctags の作法) / `repo-map` (構造 map) / `ippoan-infra-map` (基盤 5 repo の
役割分担)。
