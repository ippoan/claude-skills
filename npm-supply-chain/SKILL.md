---
name: npm-supply-chain
description: >
  Node.js プロジェクトのサプライチェーン攻撃を検出するスキル。
  node_modules とロックファイルを既知の侵害パッケージリストと照合する。
  トリガー: 「npm audit」「supply chain」「compromised」「サプライチェーン」
  「侵害パッケージ」「マルウェア検出」「npm セキュリティ」等。
user_invocable: true
---

# NPM Supply Chain Attack Scanner

PC 上の全 Node.js プロジェクトをスキャンし、既知のサプライチェーン攻撃で侵害された
パッケージバージョンがインストールされていないか検出する。

## 実行

```bash
# デフォルト (~/js, ~/rust, ~/arduino をスキャン)
bash ~/.claude/skills/npm-supply-chain/scripts/scan_compromised.sh

# 特定ディレクトリのみ
bash ~/.claude/skills/npm-supply-chain/scripts/scan_compromised.sh /home/yhonda/js

# ロックファイルのみ (node_modules なしでも検出)
bash ~/.claude/skills/npm-supply-chain/scripts/scan_compromised.sh --lock-only

# 詳細出力
bash ~/.claude/skills/npm-supply-chain/scripts/scan_compromised.sh --verbose
```

## 検出方法

1. **node_modules**: `node_modules/<pkg>/package.json` の version を照合
2. **ロックファイル**: `package-lock.json` / `yarn.lock` / `pnpm-lock.yaml` 内の version を照合

## 侵害パッケージDB

`~/.claude/skills/npm-supply-chain/data/compromised-packages.tsv`

TSV: `パッケージ名\tバージョン\t深刻度\t説明\tURL`

新しい攻撃が発見されたら1行追加するだけ。

## CRITICAL 検出時の対応

1. **INSTALLED**: 即座に安全なバージョンへ更新 (`npm install <pkg>@<safe_version>`)
2. シークレット・クレデンシャルの即時ローテーションを推奨
3. `npm audit` も追加実行して他の脆弱性を確認
