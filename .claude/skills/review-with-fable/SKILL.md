---
name: review-with-fable
description: 実装が終わった差分をFableにレビューさせる。バグ・設計の綻び・テスト漏れを指摘させたいときに使う
context: fork
agent: fable-advisor
disable-model-invocation: true
---

## レビュー対象の差分
!`git diff origin/main...HEAD`

## あなたのタスク（実装・修正はしない）
上の差分をレビューし、簡潔に返してください:
1. バグ・論理エラー・エッジケースの抜け
2. 設計上の綻び（責務の漏れ、命名、重複）
3. テストの不足（追加すべきケース）
4. 重大度（high / medium / low）順に並べる
