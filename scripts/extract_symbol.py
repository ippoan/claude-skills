#!/usr/bin/env python3
"""
extract_symbol.py — ソースファイルから特定のシンボルを抽出してコンテキストを節約する。

対応言語: Rust, Python, TypeScript/JavaScript, Go, PHP
"""

import sys
import json
import re
import argparse
from pathlib import Path


def detect_language(filepath: str) -> str:
    ext = Path(filepath).suffix.lower()
    return {
        ".rs": "rust",
        ".py": "python",
        ".ts": "typescript",
        ".tsx": "typescript",
        ".js": "javascript",
        ".jsx": "javascript",
        ".go": "go",
        ".php": "php",
    }.get(ext, "unknown")


def find_end_brace(lines: list[str], start: int) -> int:
    """開き波括弧から対応する閉じ波括弧の行インデックスを返す（文字列・コメントは簡易無視）"""
    depth = 0
    has_brace = False
    in_line_comment = False
    in_block_comment = False
    in_string = None  # None | '"' | "'"

    for i in range(start, len(lines)):
        line = lines[i]
        j = 0
        while j < len(line):
            c = line[j]
            nc = line[j + 1] if j + 1 < len(line) else ""

            if in_block_comment:
                if c == "*" and nc == "/":
                    in_block_comment = False
                    j += 1
                j += 1
                continue

            if in_line_comment:
                j += 1
                continue

            if in_string:
                if c == "\\" and nc == in_string:
                    j += 2
                    continue
                if c == in_string:
                    in_string = None
                j += 1
                continue

            if c == "/" and nc == "*":
                in_block_comment = True
                j += 2
                continue

            if c == "/" and nc == "/" or (c == "#" and j == 0):
                in_line_comment = True
                j += 1
                continue

            if c in ('"', "'"):
                in_string = c
                j += 1
                continue

            if c == "{":
                depth += 1
                has_brace = True
            elif c == "}":
                depth -= 1
                if has_brace and depth == 0:
                    return i
            j += 1

        in_line_comment = False

    return start  # ブレースが見つからない場合は開始行を返す


def find_end_python(lines: list[str], start: int) -> int:
    """Pythonブロックの終端行インデックスを返す（インデントベース）"""
    first = lines[start]
    base = len(first) - len(first.lstrip())
    last_nonempty = start

    for i in range(start + 1, len(lines)):
        stripped = lines[i].strip()
        if not stripped:
            continue
        indent = len(lines[i]) - len(lines[i].lstrip())
        if indent <= base:
            return last_nonempty
        last_nonempty = i

    return last_nonempty


def find_end_semicolon(lines: list[str], start: int) -> int:
    """セミコロン終端の1行 or 複数行定義の末尾を返す"""
    for i in range(start, min(start + 20, len(lines))):
        if ";" in lines[i]:
            return i
        if "{" in lines[i]:
            return find_end_brace(lines, i)
    return start


def get_patterns(lang: str) -> list[tuple[str, str]]:
    """(pattern, end_type) のリストを返す。end_type: brace | semicolon | python"""
    if lang == "rust":
        return [
            (r"^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+(\w+)", "brace"),
            (r"^(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)", "brace"),
            (r"^(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)", "brace"),
            (r"^(?:pub(?:\([^)]*\))?\s+)?trait\s+(\w+)", "brace"),
            (r"^impl(?:<[^>]*>)?\s+(?:[\w<>, ]+\s+for\s+)?(\w+)", "brace"),
            (r"^(?:pub(?:\([^)]*\))?\s+)?type\s+(\w+)", "semicolon"),
            (r"^(?:pub(?:\([^)]*\))?\s+)?const\s+(\w+)", "semicolon"),
            (r"^(?:pub(?:\([^)]*\))?\s+)?static\s+(?:mut\s+)?(\w+)", "semicolon"),
            # mod は意図的に除外（宣言だけで定義でないため）
        ]
    elif lang == "python":
        return [
            (r"^(?:async\s+)?def\s+(\w+)", "python"),
            (r"^class\s+(\w+)", "python"),
        ]
    elif lang in ("typescript", "javascript"):
        return [
            (r"^(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+(\w+)", "brace"),
            (r"^(?:export\s+)?(?:default\s+)?class\s+(\w+)", "brace"),
            (r"^(?:export\s+)?interface\s+(\w+)", "brace"),
            (r"^(?:export\s+)?type\s+(\w+)\s*[=<]", "semicolon"),
            (r"^(?:export\s+)?(?:const|let|var)\s+(\w+)", "semicolon"),
        ]
    elif lang == "go":
        return [
            (r"^func\s+(?:\([^)]*\)\s+)?(\w+)", "brace"),
            (r"^type\s+(\w+)\s+struct", "brace"),
            (r"^type\s+(\w+)\s+interface", "brace"),
            (r"^type\s+(\w+)", "semicolon"),
            (r"^var\s+(\w+)", "semicolon"),
            (r"^const\s+(\w+)", "semicolon"),
        ]
    elif lang == "php":
        return [
            (r"^(?:(?:public|private|protected|static|abstract|final)\s+)*function\s+(\w+)", "brace"),
            (r"^(?:abstract\s+)?(?:final\s+)?class\s+(\w+)", "brace"),
            (r"^interface\s+(\w+)", "brace"),
            (r"^trait\s+(\w+)", "brace"),
        ]
    return []


def find_symbol_end(lines, start, end_type):
    if end_type == "python":
        return find_end_python(lines, start)
    elif end_type == "semicolon":
        return find_end_semicolon(lines, start)
    else:
        return find_end_brace(lines, start)


def list_symbols(lines, lang):
    patterns = get_patterns(lang)
    symbols = []

    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue

        # トップレベルのみ（インデントなし）
        indent = len(line) - len(line.lstrip())
        if indent > 0 and lang != "php":
            continue

        for pattern, end_type in patterns:
            m = re.match(pattern, stripped)
            if m:
                end = find_symbol_end(lines, i, end_type)
                symbols.append({
                    "name": m.group(1),
                    "start_line": i + 1,
                    "end_line": end + 1,
                    "lines": end - i + 1,
                    "preview": stripped[:80].rstrip(),
                })
                break

    return symbols


def extract_by_name(lines, lang, name):
    patterns = get_patterns(lang)

    for i, line in enumerate(lines):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())
        if indent > 0 and lang not in ("php", "python"):
            continue

        for pattern, end_type in patterns:
            m = re.match(pattern, stripped)
            if m and m.group(1) == name:
                end = find_symbol_end(lines, i, end_type)
                return i, end

    return None, None


def find_rust_deps(lines, content, lang):
    """Rustのコード内で参照されている型を抽出して返す"""
    if lang != "rust":
        return []

    stdlib = {
        "String", "Vec", "HashMap", "HashSet", "Option", "Result",
        "Box", "Arc", "Rc", "Mutex", "RwLock", "Ok", "Err", "Some",
        "None", "Self", "Error", "BTreeMap", "BTreeSet", "Path",
        "PathBuf", "Duration", "Instant",
    }
    type_refs = set(re.findall(r"\b([A-Z][A-Za-z0-9]+)\b", content)) - stdlib

    deps = []
    for type_name in sorted(type_refs):
        start, end = extract_by_name(lines, lang, type_name)
        if start is not None:
            deps.append({
                "name": type_name,
                "start_line": start + 1,
                "end_line": end + 1,
                "content": "".join(lines[start:end + 1]),
            })
    return deps


def main():
    parser = argparse.ArgumentParser(description="Extract symbols from source files")
    parser.add_argument("file", help="Source file path")
    parser.add_argument("symbol", nargs="?", help="Symbol name to extract")
    parser.add_argument("--list", action="store_true", help="List all top-level symbols")
    parser.add_argument("--range", nargs=2, type=int, metavar=("START", "END"),
                        help="Extract line range (1-indexed, inclusive)")
    parser.add_argument("--with-deps", action="store_true",
                        help="Include dependent type definitions (Rust)")

    args = parser.parse_args()

    try:
        with open(args.file, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(json.dumps({"error": f"File not found: {args.file}"}))
        sys.exit(1)

    lang = detect_language(args.file)
    total = len(lines)

    def savings(extracted):
        return round((1 - extracted / total) * 100, 1) if total > 0 else 0.0

    # --- --list ---
    if args.list:
        syms = list_symbols(lines, lang)
        print(json.dumps({
            "file": args.file,
            "language": lang,
            "total_file_lines": total,
            "symbol_count": len(syms),
            "symbols": syms,
        }, ensure_ascii=False, indent=2))
        return

    # --- --range ---
    if args.range:
        s, e = args.range
        extracted = lines[s - 1:e]
        n = len(extracted)
        print(json.dumps({
            "file": args.file,
            "language": lang,
            "total_file_lines": total,
            "extracted_lines": n,
            "savings_percent": savings(n),
            "range": {"start": s, "end": e},
            "content": "".join(extracted),
        }, ensure_ascii=False, indent=2))
        return

    # --- symbol name ---
    if args.symbol:
        si, ei = extract_by_name(lines, lang, args.symbol)
        if si is None:
            print(json.dumps({"error": f"Symbol '{args.symbol}' not found", "file": args.file}))
            sys.exit(1)

        content = "".join(lines[si:ei + 1])
        n = ei - si + 1
        result = {
            "file": args.file,
            "language": lang,
            "total_file_lines": total,
            "extracted_lines": n,
            "savings_percent": savings(n),
            "symbol": {
                "name": args.symbol,
                "start_line": si + 1,
                "end_line": ei + 1,
                "content": content,
            },
        }

        if args.with_deps:
            result["dependencies"] = find_rust_deps(lines, content, lang)

        print(json.dumps(result, ensure_ascii=False, indent=2))
        return

    parser.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
