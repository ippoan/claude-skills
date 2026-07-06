#!/bin/bash
# CLAUDE.md サイズ監査 — ダイエット規約 (ippoan/claude-md#90) の ≤50 行 / ≤2000 字 を
# 満たさない CLAUDE.md を一斉検出する。
#
# 使い方:
#   audit.sh                 # 既定: このスクリプトを含む repo の親ディレクトリ配下の
#                            #        */CLAUDE.md を全部走査 (CCoW の /home/user/* 相当)
#   audit.sh <root>          # <root>/*/CLAUDE.md を走査
#   audit.sh <file>...       # 明示したファイルだけ走査 (CI の変更ファイル検査用)
#
# 出力: char 数降順の表 + サマリ。上限超過が 1 件でもあれば exit 1 (CI gate 兼用)。
# 除外: basename が CLAUDE.md 以外 / パスに /.claude/ を含む / 内容に
#       "claude-md-size-exempt" を含むもの。
set -u

MAX_LINES="${CLAUDE_MD_MAX_LINES:-50}"
MAX_CHARS="${CLAUDE_MD_MAX_CHARS:-2000}"

# --- 対象ファイルの収集 ---
files=()
if [ "$#" -eq 0 ]; then
  # 既定: このスクリプトの repo の親を root にする
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "$here/../../.." && pwd)"   # skill/scripts/audit.sh → repo → 親
  while IFS= read -r f; do files+=("$f"); done < <(find "$root" -maxdepth 2 -name CLAUDE.md -not -path '*/.claude/*' 2>/dev/null | sort)
elif [ -d "$1" ]; then
  root="$1"
  while IFS= read -r f; do files+=("$f"); done < <(find "$root" -maxdepth 2 -name CLAUDE.md -not -path '*/.claude/*' 2>/dev/null | sort)
else
  files=("$@")
fi

over=0
total_files=0
# path\tlines\tchars\tflag を貯めて後でソート
rows=""
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in CLAUDE.md) ;; *) continue ;; esac
  case "$f" in */.claude/*) continue ;; esac
  if grep -q 'claude-md-size-exempt' "$f" 2>/dev/null; then
    exempt="EXEMPT"
  else
    exempt=""
  fi
  lines=$(wc -l < "$f" | tr -d ' ')
  chars=$(wc -m < "$f" | tr -d ' ')
  total_files=$((total_files + 1))
  flag="ok"
  if [ -z "$exempt" ] && { [ "$lines" -gt "$MAX_LINES" ] || [ "$chars" -gt "$MAX_CHARS" ]; }; then
    flag="OVER"
    over=$((over + 1))
  fi
  [ -n "$exempt" ] && flag="exempt"
  rows+="$chars	$lines	$flag	$f
"
done

printf 'CLAUDE.md size audit (limit: ≤%s lines / ≤%s chars)\n' "$MAX_LINES" "$MAX_CHARS"
printf '%8s  %6s  %-6s  %s\n' "chars" "lines" "status" "path"
printf '%s' "$rows" | sort -rn | while IFS=$'\t' read -r chars lines flag path; do
  [ -z "$path" ] && continue
  printf '%8s  %6s  %-6s  %s\n' "$chars" "$lines" "$flag" "$path"
done

printf '\n%s files scanned, %s OVER limit.\n' "$total_files" "$over"
[ "$over" -eq 0 ]
