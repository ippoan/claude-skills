---
name: memory-prune
description: MEMORY.md が肥大化した時に handover 以外の memory file を skills や CLAUDE.md に移行してスリム化するスキル。handover_*.md は memory に残す方針 (ephemeral)。それ以外の feedback / reference / 完了 progress は workflow-bound なら既存 skill SKILL.md、universal rule なら CLAUDE.md、situational なら新規 grouped skill に振り分ける。2026 best practice (sabrina.dev / Anthropic skills launch 2025-10) ベース。トリガー: 「memory 整理」「MEMORY.md スリム化」「memory 肥大化」「feedback skill 化」「memory 削減」「memory cleanup」「200 行超えた」「25KB 超えた」「auto-memory が増えすぎ」等。/memory-prune で呼び出し可能。
---

# memory-prune — handover 以外を skills / CLAUDE.md に分散

## 適用条件

`~/.claude/projects/<project>/memory/MEMORY.md` が以下のいずれかに該当する時:

- 200 行 超え (公式 docs threshold、超過分は session start で load されない)
- 25KB 近接 (同 threshold、bytes 側)
- `feedback_*.md` / `reference_*.md` が増えて bloat
- user が「memory 肥大化」「整理して」等と発言

## 前提: 新規 memory routing は global CLAUDE.md `## Memory routing` に集約済

このスキルは **既存 memory を再分散** する処理。**新規 feedback / 知見の入口ルーティング**
(どこに書くか) は `~/.claude/CLAUDE.md` の `## Memory routing` section に書いてある。
両者は補完関係:

- **入口 (prevention)**: `~/.claude/CLAUDE.md` `## Memory routing` — 新規書き込み時の振り分け
- **出口 (reactive cleanup)**: この skill — bloat 発生時の再分散

`## Memory routing` のルールに従えば、handover_* と判断保留以外は memory dir に
新規 file が増えなくなる。それでも増えたら (auto-memory が default に従って書いた等)
この skill で再分散する。

## 設計原則 (2026 best practice)

| memory file 種別 | 移行先 | 判定基準 |
|---|---|---|
| `handover_*.md` | **memory のまま** | session 横断の work snapshot、ephemeral、機械ローカルで OK |
| Workflow-bound feedback | **既存 skill `SKILL.md` に統合** | wt-quick / pr-push / tag-release / ci-init 等 task trigger 有り |
| Universal rule | **CLAUDE.md (global or project)** | "always X" / "never Y"、横断、常時 load 価値あり |
| Situational reference | **新規 grouped skill** | description trigger で auto-load (GHCR 障害 / auth gotcha 等) |
| Progress / design doc | **repo の docs/ or .claude/plans/** | git tracked、必要時参照 |
| 判断不能 | **memory のまま** | 無理に動かさない |

参考:
- 公式 docs: https://code.claude.com/docs/en/memory
- sabrina.dev 2026 整理: https://www.sabrina.dev/p/every-claude-code-concept-explained-beginners
- skills 公式: https://claude.com/skills

## 実行手順

### Step 1: 現状分析

```bash
# project 名 (cwd ベースで自動判定)
PROJ=$(echo "$PWD" | sed 's|/|-|g')
MEM=~/.claude/projects/$PROJ/memory
cd "$MEM"

echo "=== MEMORY.md ==="
echo "lines: $(wc -l < MEMORY.md)"
echo "bytes: $(wc -c < MEMORY.md)"
echo
echo "=== 種別カウント ==="
echo "handover: $(ls handover_*.md 2>/dev/null | wc -l)"
echo "feedback: $(ls feedback_*.md 2>/dev/null | wc -l)"
echo "reference: $(ls reference_*.md 2>/dev/null | wc -l)"
echo "其他: $(ls *.md 2>/dev/null | grep -vE '^(MEMORY|handover_|feedback_|reference_)' | wc -l)"
echo
echo "=== 200 行 / 25KB threshold 確認 ==="
LINES=$(wc -l < MEMORY.md); BYTES=$(wc -c < MEMORY.md)
[ "$LINES" -gt 200 ] && echo "WARN: $LINES 行 > 200 limit"
[ "$BYTES" -gt 25600 ] && echo "WARN: $BYTES bytes > 25KB limit"
```

### Step 2: 分類

`handover_*.md` 以外の各 file を Read し、内容に基づき以下のいずれかに分類:

- **A. Workflow → 既存 skill**
  - `~/.claude/skills/*/SKILL.md` の description / トリガー keyword と一致するか確認
  - 一致するなら該当 skill の SKILL.md に追記対象
- **B. Universal rule → CLAUDE.md**
  - "always X" / "never Y" 型の横断的禁則 / 推奨
  - 移行先: global = `~/.claude/CLAUDE.md`, project = repo の `CLAUDE.md`
- **C. Situational → 新規 grouped skill**
  - debug / 障害対応 / 復旧手順 (例: GHCR PAT 失効、auth cookie 罠、npm 2FA など)
  - 複数の関連 feedback をまとめて 1 skill に
- **D. Progress / design doc → repo の docs/**
  - 進捗管理、設計 doc、checklist 等。git tracked にする
- **E. 判断不能 → memory に残す**
  - 動かさない方が安全

### Step 3: AskUserQuestion で分類結果を user 承認

各バッチ (5〜10 件) ごとに分類リストを提示 → user の OK/修正を貰う。
判断が割れる項目は memory 残置に倒す (保守的)。

### Step 4: 移行実行 (1 件ずつ atomic)

各 file について:

1. 対象 memory file を Read
2. destination file (SKILL.md / CLAUDE.md / docs) に追記
   - 末尾の「罠」「Pitfalls」「Gotchas」section に追加
   - provenance コメント: `<!-- migrated from memory/feedback_xxx.md (YYYY-MM-DD) -->`
   - 既存 SKILL.md なら frontmatter description の trigger keyword も update
3. 対象 memory file を `rm`
4. MEMORY.md から該当 index 行を Edit で削除 (replace_all=false)

**順序重要**: destination 追記 → memory 削除 → MEMORY.md 行削除。途中失敗時に情報を失わない。

### Step 4.5: baseline 更新

移行完了後に baseline file を `touch` する。SessionStart hook
(`~/.claude/hooks/session-start-memory-baseline.sh`) はこの baseline 以降に追加された
非 handover file を検知して警告を出すので、prune 完了時点が baseline になる:

```bash
touch "$MEM/.memory-prune-baseline"
```

(`$MEM` は Step 1 で定義した memory dir パス)

### Step 5: Verification

```bash
PROJ=$(echo "$PWD" | sed 's|/|-|g')
MEM=~/.claude/projects/$PROJ/memory
cd "$MEM"

echo "=== 行数 / bytes ==="
wc -l MEMORY.md
wc -c MEMORY.md

echo "=== 非 index 行 (全 entry が index 形式か) ==="
grep -nE '^- ' MEMORY.md | grep -vE '\[.+\]\(.+\.md\)' || echo "(全 entry が index 形式 OK)"

echo "=== orphan check (MEMORY.md から参照されない handover 以外 file) ==="
for f in *.md; do
  [ "$f" = "MEMORY.md" ] && continue
  case "$f" in handover_*) continue ;; esac
  grep -q "$f" MEMORY.md || echo "orphan: $f"
done

echo "=== 移行先確認 ==="
grep -l 'migrated from memory' ~/.claude/skills/*/SKILL.md 2>/dev/null
```

## 新規 skill 作成テンプレ

Situational reference を grouping する場合:

```bash
SKILL=package-publish-debug
mkdir -p ~/.claude/skills/$SKILL
cat > ~/.claude/skills/$SKILL/SKILL.md <<'EOF'
---
name: <skill-name>
description: <一行説明>。トリガー: 「keyword1」「keyword2」「keyword3」等。
---

# <skill-name>

<本文の説明>

## 関連した過去の罠 / Pitfalls

<!-- migrated from memory/feedback_xxx.md (YYYY-MM-DD) -->
- <feedback の要点>

<!-- migrated from memory/feedback_yyy.md (YYYY-MM-DD) -->
- <feedback の要点>
EOF
```

description には複数の trigger keyword を含めること (Claude が自動 load 判断する)。

## 注意

- `handover_*.md` は touch しない (memory に残す方針)
- 既存 SKILL.md 追記時は description の trigger keyword も update する
- CLAUDE.md 追記時は重複チェック (既存 rule と被るなら memory 削除のみで destination は触らない)
- 1 セッションで全件やらない、確実な分類だけバッチ実行
- 判断不能は無理に動かさない (E カテゴリ = memory 残置 OK)
- 完了は target が 200 行未満になったら一旦停止 (incremental progress)
- 次回 bloat 時にまた `/memory-prune` を呼べばよい (構造化されているので再実行可能)

## 関連

- 公式 memory docs: https://code.claude.com/docs/en/memory
- skill 作成ガイド: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
