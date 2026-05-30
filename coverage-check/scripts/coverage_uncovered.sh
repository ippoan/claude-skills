#!/usr/bin/env bash
# coverage_uncovered.sh — cargo llvm-cov --text から未カバー行を抽出
#
# Usage:
#   coverage_uncovered.sh <file_pattern>          # 未カバー行を表示
#   coverage_uncovered.sh --context <pattern>     # 未カバー行 + 前後3行コンテキスト
#   coverage_uncovered.sh --summary               # カバレッジサマリ
#   coverage_uncovered.sh --list                  # 未カバーがあるファイル一覧
#   coverage_uncovered.sh --refresh <pattern>     # キャッシュを無視して再実行
#   coverage_uncovered.sh --full <pattern>        # サマリ + 未カバー行 (1回の実行で両方)
#   coverage_uncovered.sh --not-100              # 100%未達成ファイル一覧 (キャッシュから)
#
# Examples:
#   coverage_uncovered.sh dtako_upload.rs
#   coverage_uncovered.sh --context dtako_upload.rs
#   coverage_uncovered.sh --full dtako_upload.rs      # サマリ + 未カバー行 一括
#   coverage_uncovered.sh --refresh --full auth.rs    # リフレッシュ + 一括
#   coverage_uncovered.sh --list
#   coverage_uncovered.sh --summary
#   coverage_uncovered.sh --not-100                   # 100%未達成のみ表示

set -euo pipefail

CACHE_DIR="/tmp/llvm-cov-cache"
mkdir -p "$CACHE_DIR"

PROJECT_HASH=$(echo "$PWD" | md5sum | cut -c1-8)
CACHE_FILE="$CACHE_DIR/text-$PROJECT_HASH.txt"
CACHE_STAMP="$CACHE_DIR/stamp-$PROJECT_HASH"
SUMMARY_CACHE="$CACHE_DIR/summary-$PROJECT_HASH.txt"

refresh=false
mode="uncovered"
context=false
full=false
pattern=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary)  mode="summary"; shift ;;
        --list)     mode="list"; shift ;;
        --not-100)  mode="not100"; shift ;;
        --refresh)  refresh=true; shift ;;
        --context)  context=true; shift ;;
        --full)     full=true; shift ;;
        --help|-h)  head -19 "$0" | tail -18; exit 0 ;;
        *)          pattern="$1"; shift ;;
    esac
done

# awk でサマリ集計 (--text 出力から)
# 行フォーマット: "  行番号|  実行回数|コード"
#   "    1|       |..." = 実行不可行 (空白) → カウントしない
#   "    1|      0|..." = uncovered (0回)
#   "    1|     10|..." = covered (10回以上)
generate_summary() {
    local cache="$1"
    awk '
    /^\/home.*\/src\/.*\.rs:$/ {
        if (file != "") {
            total = covered + uncovered
            pct = (total > 0) ? sprintf("%.2f%%", covered * 100.0 / total) : "-"
            printf "%-45s %5d %5d %8s\n", file, total, uncovered, pct
            grand_total += total; grand_uncov += uncovered
        }
        file = $0; sub(/:$/, "", file); sub(/.*\/src\//, "", file)
        covered = 0; uncovered = 0; next
    }
    # 実行回数が 0 の行 (uncovered)
    /^[[:space:]]*[0-9]+\|[[:space:]]*0\|/ { uncovered++; next }
    # 実行回数が 1 以上の行 (covered) — 空白のみの行を除外
    /^[[:space:]]*[0-9]+\|[[:space:]]*[1-9][0-9]*\|/ { covered++; next }
    END {
        if (file != "") {
            total = covered + uncovered
            pct = (total > 0) ? sprintf("%.2f%%", covered * 100.0 / total) : "-"
            printf "%-45s %5d %5d %8s\n", file, total, uncovered, pct
            grand_total += total; grand_uncov += uncovered
        }
        printf "%-45s %5d %5d %8s\n", "TOTAL", grand_total, grand_uncov, \
            (grand_total > 0) ? sprintf("%.2f%%", (grand_total - grand_uncov) * 100.0 / grand_total) : "-"
    }
    ' "$cache"
}

# サマリ専用モード
if [[ "$mode" == "summary" && "$full" == false ]]; then
    # キャッシュがなければビルド
    if [[ ! -f "$CACHE_FILE" ]]; then
        echo ">>> Running cargo llvm-cov --text (this may take a while)..." >&2
        [[ -f .test-config ]] && source .test-config
        cargo llvm-cov --text > "$CACHE_FILE" 2>&1
        touch "$CACHE_STAMP"
        echo ">>> Cached to $CACHE_FILE" >&2
    fi
    echo "=== Coverage Summary ==="
    printf "%-45s %5s %5s %8s\n" "File" "Lines" "Miss" "Cover"
    printf "%s\n" "-------------------------------------------------------------------"
    generate_summary "$CACHE_FILE"
    exit 0
fi

# 100% 未達成ファイル一覧モード (キャッシュから取得)
if [[ "$mode" == "not100" ]]; then
    if [[ "$refresh" == true ]] || [[ ! -f "$CACHE_FILE" ]]; then
        echo ">>> Running cargo llvm-cov --text (this may take a while)..." >&2
        [[ -f .test-config ]] && source .test-config
        cargo llvm-cov --text > "$CACHE_FILE" 2>&1
        touch "$CACHE_STAMP"
        generate_summary "$CACHE_FILE" > "$SUMMARY_CACHE"
        echo ">>> Cached to $CACHE_FILE" >&2
    fi
    echo "=== Files NOT at 100% coverage ==="
    printf "%-45s %5s %5s %8s\n" "File" "Lines" "Miss" "Cover"
    printf "%s\n" "-------------------------------------------------------------------"
    awk '
    /^\/home.*\/src\/.*\.rs:$/ {
        if (file != "") {
            total = covered + uncovered
            if (uncovered > 0 && total > 0) {
                pct = sprintf("%.2f%%", covered * 100.0 / total)
                printf "%-45s %5d %5d %8s\n", file, total, uncovered, pct
                count++; grand_miss += uncovered
            }
        }
        file = $0; sub(/:$/, "", file); sub(/.*\/src\//, "", file)
        covered = 0; uncovered = 0; next
    }
    /^[[:space:]]*[0-9]+\|[[:space:]]*0\|/ { uncovered++; next }
    /^[[:space:]]*[0-9]+\|[[:space:]]*[1-9][0-9]*\|/ { covered++; next }
    END {
        if (file != "") {
            total = covered + uncovered
            if (uncovered > 0 && total > 0) {
                pct = sprintf("%.2f%%", covered * 100.0 / total)
                printf "%-45s %5d %5d %8s\n", file, total, uncovered, pct
                count++; grand_miss += uncovered
            }
        }
        printf "-------------------------------------------------------------------\n"
        printf "%d files, %d total uncovered lines\n", count, grand_miss
    }
    ' "$CACHE_FILE"
    exit 0
fi

# キャッシュ判定
needs_rebuild=false
if [[ "$refresh" == true ]] || [[ ! -f "$CACHE_FILE" ]] || [[ ! -f "$CACHE_STAMP" ]]; then
    needs_rebuild=true
elif [[ -n $(find src tests -newer "$CACHE_STAMP" -name '*.rs' -type f 2>/dev/null | head -1) ]]; then
    needs_rebuild=true
fi

if [[ "$needs_rebuild" == true ]]; then
    echo ">>> Running cargo llvm-cov --text (this may take a while)..." >&2
    [[ -f .test-config ]] && source .test-config
    cargo llvm-cov --text > "$CACHE_FILE" 2>&1
    touch "$CACHE_STAMP"
    # サマリを awk で集計してキャッシュ
    generate_summary "$CACHE_FILE" > "$SUMMARY_CACHE"
    echo ">>> Cached to $CACHE_FILE" >&2
fi

# --full モード: サマリ + 未カバー行を1回で表示
if [[ "$full" == true ]]; then
    if [[ -z "$pattern" ]]; then
        echo "Error: --full requires a file pattern" >&2
        exit 1
    fi

    # サマリ (キャッシュから、なければ生成)
    if [[ ! -s "$SUMMARY_CACHE" ]] && [[ -f "$CACHE_FILE" ]]; then
        generate_summary "$CACHE_FILE" > "$SUMMARY_CACHE"
    fi
    echo "=== Summary ==="
    printf "%-45s %5s %5s %8s\n" "File" "Lines" "Miss" "Cover"
    printf "%s\n" "-------------------------------------------------------------------"
    if [[ -s "$SUMMARY_CACHE" ]]; then
        grep -i "$pattern\|^TOTAL" "$SUMMARY_CACHE" | head -5
    fi
    echo ""

    # 未カバー行
    if [[ "$context" == true ]]; then
        # コンテキストモード
        src_file=$(awk -v pat="$pattern" '
        /^\/home.*\.rs:$/ {
            f = $0; sub(/:$/, "", f)
            if (index(f, pat) > 0) { print f; exit }
        }' "$CACHE_FILE")

        if [[ -z "$src_file" ]]; then
            echo "No file matching '$pattern'" >&2
            exit 1
        fi

        display="$src_file"
        display=${display/*\/src\//src/}
        echo "=== $display ==="

        lines=$(awk -v pat="$pattern" '
        /^\/home.*\.rs:$/ { in_target = (index($0, pat) > 0) ? 1 : 0; next }
        /^$/ { in_target = 0; next }
        in_target && /^[[:space:]]+[0-9]+\|[[:space:]]+0\|/ {
            match($0, /^[[:space:]]*([0-9]+)\|/, arr)
            if (RSTART > 0) print arr[1]
        }' "$CACHE_FILE")

        if [[ -z "$lines" ]]; then
            echo "(no uncovered lines)"
        else
            for line in $lines; do
                start=$((line - 3)); [[ $start -lt 1 ]] && start=1
                end=$((line + 3))
                echo ""
                echo "--- line $line ---"
                sed -n "${start},${end}p" "$src_file" | awk -v target="$line" -v s="$start" '{
                    n = s + NR - 1
                    marker = (n == target) ? ">>>" : "   "
                    printf "%s %4d: %s\n", marker, n, $0
                }'
            done
        fi
        count=$(echo "$lines" | grep -c . || true)
    else
        # 通常モード
        awk -v pat="$pattern" '
        /^\/home.*\.rs:$/ {
            file = $0; sub(/:$/, "", file)
            in_target = (index(file, pat) > 0) ? 1 : 0
            if (in_target) {
                display = file
                sub(/.*\/src\//, "src/", display)
                print "\n=== " display " ==="
            }
            next
        }
        /^$/ { in_target = 0; next }
        in_target && /^[[:space:]]+[0-9]+\|[[:space:]]+0\|/ {
            line = $0
            match(line, /^[[:space:]]*([0-9]+)\|[[:space:]]*0\|(.*)$/, arr)
            if (RSTART > 0) printf "%6s: %s\n", arr[1], arr[2]
        }
        ' "$CACHE_FILE"

        count=$(awk -v pat="$pattern" '
        /^\/home.*\.rs:$/ { in_target = (index($0, pat) > 0) ? 1 : 0; next }
        /^$/ { in_target = 0; next }
        in_target && /^[[:space:]]+[0-9]+\|[[:space:]]+0\|/ { count++ }
        END { print count }
        ' "$CACHE_FILE")
    fi

    echo ""
    echo "--- Total uncovered lines: $count ---"
    exit 0
fi

# リストモード
if [[ "$mode" == "list" ]]; then
    echo "=== Files with uncovered lines ==="
    awk '
    /^\/home.*\.rs:$/ {
        if (file != "" && count > 0) printf "%4d  %s\n", count, file
        file = $0; sub(/:$/, "", file)
        n = split(file, parts, "/")
        file = parts[n]
        count = 0; next
    }
    /^[[:space:]]+[0-9]+\|[[:space:]]+0\|/ { count++ }
    END { if (file != "" && count > 0) printf "%4d  %s\n", count, file }
    ' "$CACHE_FILE" | sort -rn
    exit 0
fi

# 未カバーモード: パターン必須
if [[ -z "$pattern" ]]; then
    echo "Error: file pattern required. Usage: $0 <file_pattern>" >&2
    exit 1
fi

# コンテキストモード
if [[ "$context" == true ]]; then
    src_file=$(awk -v pat="$pattern" '
    /^\/home.*\.rs:$/ {
        f = $0; sub(/:$/, "", f)
        if (index(f, pat) > 0) { print f; exit }
    }' "$CACHE_FILE")

    if [[ -z "$src_file" ]]; then
        echo "No file matching '$pattern'" >&2
        exit 1
    fi

    display="$src_file"
    display=${display/*\/src\//src/}
    echo "=== $display ==="

    lines=$(awk -v pat="$pattern" '
    /^\/home.*\.rs:$/ { in_target = (index($0, pat) > 0) ? 1 : 0; next }
    /^$/ { in_target = 0; next }
    in_target && /^[[:space:]]+[0-9]+\|[[:space:]]+0\|/ {
        match($0, /^[[:space:]]*([0-9]+)\|/, arr)
        if (RSTART > 0) print arr[1]
    }' "$CACHE_FILE")

    if [[ -z "$lines" ]]; then
        echo "(no uncovered lines)"
    else
        for line in $lines; do
            start=$((line - 3)); [[ $start -lt 1 ]] && start=1
            end=$((line + 3))
            echo ""
            echo "--- line $line ---"
            sed -n "${start},${end}p" "$src_file" | awk -v target="$line" -v s="$start" '{
                n = s + NR - 1
                marker = (n == target) ? ">>>" : "   "
                printf "%s %4d: %s\n", marker, n, $0
            }'
        done
    fi

    count=$(echo "$lines" | grep -c . || true)
    echo ""
    echo "--- Total uncovered lines: $count ---"
    exit 0
fi

# 通常モード
awk -v pat="$pattern" '
/^\/home.*\.rs:$/ {
    file = $0; sub(/:$/, "", file)
    in_target = (index(file, pat) > 0) ? 1 : 0
    if (in_target) {
        display = file
        sub(/.*\/src\//, "src/", display)
        print "\n=== " display " ==="
    }
    next
}
/^$/ { in_target = 0; next }
in_target && /^[[:space:]]+[0-9]+\|[[:space:]]+0\|/ {
    line = $0
    match(line, /^[[:space:]]*([0-9]+)\|[[:space:]]*0\|(.*)$/, arr)
    if (RSTART > 0) printf "%6s: %s\n", arr[1], arr[2]
}
' "$CACHE_FILE"

count=$(awk -v pat="$pattern" '
/^\/home.*\.rs:$/ { in_target = (index($0, pat) > 0) ? 1 : 0; next }
/^$/ { in_target = 0; next }
in_target && /^[[:space:]]+[0-9]+\|[[:space:]]+0\|/ { count++ }
END { print count }
' "$CACHE_FILE")

echo ""
echo "--- Total uncovered lines: $count ---"
