---
name: claude-md-audit
description: CLAUDE.md ダイエット (ippoan/claude-md#90) の監査ツール。org 全 repo の CLAUDE.md サイズ (行数/文字数) を一斉検出し、≤50 行 / ≤2000 字 の上限を超えている「ダイエット対象」を降順で列挙する。共通規範は user memory に集約・repo 固有の詳細は <repo>-map skill へ退避、という方針に対して「どの repo がまだ肥大しているか」を機械的に洗い出すために使う。PreToolUse hook (claude-hooks/pre-tool-claude-md-size.sh) と ci-workflows の CI gate と同じ 50/2000 の閾値・exempt marker (claude-md-size-exempt) を共有する。トリガー:「CLAUDE.md サイズ」「ダイエット対象 検出」「CLAUDE.md 監査」「どの repo が肥大」「CLAUDE.md 一斉検出」「claude-md-audit」「50行 2000字 超過」等。
---

# claude-md-audit — CLAUDE.md サイズ一斉検出

CLAUDE.md ダイエット (ippoan/claude-md#90) の対象洗い出しツール。

## 使い方

```sh
# CCoW: /home/user/*/CLAUDE.md を全部監査 (このスクリプトの repo の親を root にする)
bash ~/.claude/skills/claude-md-audit/scripts/audit.sh

# root を明示
bash ~/.claude/skills/claude-md-audit/scripts/audit.sh /home/user

# 変更ファイルだけ (CI の gate 用途)
bash .../audit.sh path/to/CLAUDE.md another/CLAUDE.md
```

出力は char 数降順の表 (`chars / lines / status / path`) とサマリ。上限
(既定 ≤50 行 / ≤2000 字、`CLAUDE_MD_MAX_LINES` / `CLAUDE_MD_MAX_CHARS` で上書き可)
を超える CLAUDE.md が 1 件でもあれば **exit 1** を返す (CI gate 兼用)。

## 判定ルール (hook / CI と共通)

- 対象: basename がちょうど `CLAUDE.md` のファイル。
- 除外: パスに `/.claude/` を含むもの (user memory 等)。
- exempt: 内容に `claude-md-size-exempt` を含めば許可 (意図的な大型)。

## ダイエットの進め方 (超過 repo が出たら)

1. その repo の詳細 (テーブル定義・エンドポイント表・gotcha・デプロイ手順) を
   `<repo>-map` skill (lazy) へ退避する。map が無ければ `repo-map` skill で作る。
2. CLAUDE.md には identity 1 段落・「まず読むもの」条件付きポインタ・repo 固有の
   1 行 invariant だけを残す (共通規範は user memory にあるので繰り返さない)。
3. 再度 audit を回して ≤50 行 / ≤2000 字 に収まったことを確認する。

規約の SoT は `ippoan/claude-md` の `CLAUDE.md.template` と `.claude/user-memory.md`。
