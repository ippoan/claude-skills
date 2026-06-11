---
title: generated-from 新形式 (tree-sha → commit-sha + paths)
date: 2026-06-11
status: active
tags: [generated-from, skill-freshness, ci, map]
repo: claude-hooks
issue: 18
---

## Summary

`<repo>-map` skill の鮮度トラッキング frontmatter を、`generated-from: <repo>:<tree-sha>`
から **`generated-from: <repo>:<commit-sha>` + `paths: [...]`** に改める。tree-sha は
完全一致判定のため 1 コミットで常時 stale 化していた (オオカミ少年)。commit-sha は
乖離距離を測れ、paths は stale 判定を「map が参照するパスの変更」に限定できる。

## Context

claude-hooks の `session-start-skill-coverage.sh` の stale 警告が CCoW で機能して
いなかった。判定ロジック側の原因:

- **tree-sha 完全一致**: 記録 tree-sha と現在 tree-sha が 1 文字でも違えば stale。
  map と無関係な変更 (README 等) でも即 stale 化し、警告がノイズになり沈んだ。
- 鮮度距離が測れない (一致 / 不一致の 2 値のみ)。
- そもそも SessionStart hook の warn は CCoW で無視されがち (deny する guard しか
  効かないことが実証済み)。

## Decision

1. **commit-sha**: 生成時の `git rev-parse HEAD` (tree でなく commit) を記録する。
   CI が `git rev-list --count <commit>..HEAD -- <paths>` で**乖離距離**を測れる。
2. **paths 必須**: map が参照するコードのスコープを明示し、**その paths 下に変更が
   あった時だけ stale 扱い**にする。
3. **stale 判定を CI へ移譲** (ci-workflows#118 `skills-check.yml`、PR diff 判定)。
   SessionStart hook は「map の無い attached repo の通知」だけに縮小 (claude-hooks#18 PR2)。
4. map は各 repo の `.claude/skills/<repo>-map/` へ同居移行 (claude-skills#59)。
   コードと同じ PR で更新されるため、クロスリポ書き込み・push 忘れ消失が消える。
5. **移行期間**: 旧形式 (tree-sha / paths 無し) は warn のみで判定スキップ。
   横断 map (`ippoan-infra-map` 等、複数 repo を space 区切り) は移行対象外で当面 tree-sha 維持。

本 PR1 では `repo-map` / `cross-repo-symbol-index` skill の規約を新形式に改訂した
(仕様確定)。hook 縮小は claude-hooks#18 PR2、CI 実装は ci-workflows#118。

## Rejected alternatives

- **tree-sha 維持 + 閾値緩和** — 完全一致をやめても tree-sha では「どの paths が
  変わったか」を切り出せず、無関係変更での誤検出は消えない。paths スコープが本質。
- **hook 側で stale 判定を継続** — SessionStart warn は CCoW で無視される実績があり、
  強制力を持つ CI (PR 上で機械的に warn/fail) へ移すのが妥当。
