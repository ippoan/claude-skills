---
name: egov-spec
description: >
  e-Gov Developer Portal から電子申請API関連の仕様書・スキーマをダウンロード・展開するスキル。
  構成管理スキーマ(kousei.xsd)、手続情報一覧/提出先一覧、社会保険関係手続の申請書様式構造仕様を取得する。
  トリガー: 「スキーマ取得」「schema fetch」「仕様書ダウンロード」「e-Gov仕様」
  「構成管理スキーマ」「手続一覧ダウンロード」「申請書様式」「提出先一覧」等。
---

# e-Gov 仕様書取得

e-Gov Developer Portal から仕様書をダウンロードして `spec/` ディレクトリに展開する。

## コマンド

```bash
SCRIPT="$HOME/.claude/skills/egov-spec/scripts/fetch-spec.sh"

# 全部取得
bash $SCRIPT /path/to/project --all

# 個別取得
bash $SCRIPT /path/to/project --schema           # 構成管理スキーマ (kousei.xsd)
bash $SCRIPT /path/to/project --procedures        # 手続情報一覧・提出先一覧
bash $SCRIPT /path/to/project --social-insurance  # 社会保険関係手続
```

## 取得される仕様書

| オプション | 内容 | 展開先 |
|---|---|---|
| `--schema` | 構成管理XMLスキーマ (kousei.xsd等) | `spec/kousei_schema/` |
| `--procedures` | 手続情報一覧・提出先一覧 (最新版を自動検出) | `spec/tetsuzuki/` |
| `--social-insurance` | 社会保険関係手続の申請書様式構造仕様 | `spec/shakai/` |

## ソース

- 構成管理スキーマ: https://developer.e-gov.go.jp/contents/specification/document-api/schema-file.html
- 手続情報・様式仕様: https://developer.e-gov.go.jp/contents/specification/document-api/specification.html
- 社会保険関係手続: https://developer.e-gov.go.jp/contents/specification/document-api/social-insurance.html
