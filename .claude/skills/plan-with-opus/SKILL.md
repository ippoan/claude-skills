---
name: plan-with-opus
description: コードを読んで詳細な実装計画とPR分割をOpusに作らせる。Issueの高レベル計画を実装可能なタスクに落とすときに使う
context: fork
agent: opus-advisor
disable-model-invocation: true
---

## 対象の課題 / Issue
$ARGUMENTS

## あなたのタスク（実装はしない）
関連コードを読み、上記課題の詳細な実装計画を作成してください。
必ず含めること:
1. 影響範囲（変更が必要なファイル/モジュールと理由）
2. PR分割案（各PRの粒度・順序・依存関係）
3. 各PRのタスク（GitHubタスクリスト `- [ ]` 形式）
4. 先に決めるべき設計判断・リスク
