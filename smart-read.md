---
name: smart-read
description: ファイル全体を読まずに特定の関数・構造体・traitだけを抽出してコンテキストを節約する。コードの定義を確認するとき、関数を修正するとき、シンボルの内容を調べるときに使用。Rust, PHP, Python, TypeScript, Go に対応。
allowed-tools: Bash(python3:*), Read
---

# Smart Read — シンボル単位の抽出でコンテキストを節約

ファイル全体を Read する代わりに、必要なシンボルだけを取り出す。
スクリプト: `~/.claude/skills/scripts/extract_symbol.py`

```bash
SCRIPT="$HOME/.claude/skills/scripts/extract_symbol.py"
```

---

## いつ使うか / 使わないか

| 使う | 使わない |
|------|---------|
| 関数・構造体・traitの定義確認 | ファイルが 50 行以下 |
| 修正対象の関数だけ読みたい | 設定ファイル (toml/yaml/json) |
| LSP で位置がわかったとき | ファイル全体の把握が必要なとき |
| 大きなファイルの構造把握 | |

---

## コマンド

### シンボル一覧を取得（内容は読まない）

```bash
SCRIPT="$HOME/.claude/skills/scripts/extract_symbol.py"
python3 "$SCRIPT" src/handlers/measurements.rs --list
```

出力例:
```json
{
  "total_file_lines": 420,
  "symbol_count": 12,
  "symbols": [
    { "name": "CreateMeasurement", "start_line": 15, "end_line": 28, "lines": 14, "preview": "pub struct CreateMeasurement {" },
    { "name": "create_measurement", "start_line": 45, "end_line": 98, "lines": 54, "preview": "pub async fn create_measurement(" }
  ]
}
```

### 特定のシンボルだけ抽出

```bash
SCRIPT="$HOME/.claude/skills/scripts/extract_symbol.py"
python3 "$SCRIPT" src/handlers/measurements.rs create_measurement
```

### 依存型も一緒に取得（Rust）

```bash
SCRIPT="$HOME/.claude/skills/scripts/extract_symbol.py"
python3 "$SCRIPT" src/handlers/measurements.rs create_measurement --with-deps
```

`create_measurement` が使っている struct/enum を同時に抽出する。

### 行範囲で抽出（LSP の goToDefinition 結果と組み合わせ）

```bash
SCRIPT="$HOME/.claude/skills/scripts/extract_symbol.py"
python3 "$SCRIPT" src/models.rs --range 45 82
```

---

## 典型的なワークフロー

### 関数を修正する

1. `--list` でシンボル一覧 → 対象の行範囲を確認
2. 関数名で抽出（大きな関数なら `--with-deps` も）
3. 修正を実施
4. テスト実行

### 呼び出し元を調査する

1. Grep で呼び出し元ファイル:行を列挙
2. 各ファイルで `--range` を使って該当箇所だけ抽出
3. ファイル全体は読まない

---

## 出力フォーマット

```json
{
  "file": "src/handlers/measurements.rs",
  "language": "rust",
  "total_file_lines": 420,
  "extracted_lines": 54,
  "savings_percent": 87.1,
  "symbol": {
    "name": "create_measurement",
    "start_line": 45,
    "end_line": 98,
    "content": "..."
  }
}
```

`savings_percent` でどれだけコンテキストを節約できたか確認できる。
エラー時は `{ "error": "Symbol 'foo' not found", "file": "..." }` が返る。
