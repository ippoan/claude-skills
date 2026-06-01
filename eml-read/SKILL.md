---
name: eml-read
description: >
  .eml (RFC822 メール) を人間可読テキストに変換するスキル。MIME ヘッダの
  RFC2047 (=?UTF-8?B?...?=) を decode し、本文を charset 解決して表示、添付を
  保存する。PPAP (パスワード付き zip + パスワード別メール) の受領にも対応 —
  zip 添付をパスワードで解凍する。ref-files から落とした .eml をそのまま
  Read tool で開くと base64/MIME で読めないため、その前段で使う (ref-files-bulk
  と相補的)。
  トリガー: 「eml 読む」「メール解読」「.eml 開く」「メール本文デコード」
  「添付取り出し」「PPAP 解凍」「パスワード付き zip 受領」「=?UTF-8?B?」
  「メールの中身確認」「eml-read」等。
---

# eml-read

`.eml` (RFC822) を人間可読化するスキル。MIME なので Read tool でそのまま開くと
ヘッダは `=?UTF-8?B?...?=`、本文・添付は base64/quoted-printable で読めない。
このスキルの `scripts/eml-read.py` が decode する。

ref-files の往復メール (`spec/*.eml`) を読む時や、PPAP で受け取った
パスワード付き zip を開く時に使う。`folder_download_url` / ref-files-bulk で
.eml を local に落としてから、このスキルで中身を読む流れ。

## 基本: メールを読む

```bash
python3 ~/.claude/skills/eml-read/scripts/eml-read.py <file.eml>
```

出力:
- ヘッダ (Subject / From / To / Cc / Date) を RFC2047 decode
- text/plain 本文を charset 解決して表示 (無ければ text/html を簡易タグ除去)
- 添付一覧 (filename も RFC2047 decode)

## 添付を保存

```bash
python3 ~/.claude/skills/eml-read/scripts/eml-read.py <file.eml> --attach-dir /tmp/att
```

添付実体を `/tmp/att/` に書き出す (base64 を context に載せない)。

## PPAP 受領 (パスワード付き zip + パスワード別メール)

日本の行政・企業でよくある PPAP。**2 通**で届く:
1. 本文 + パスワード付き zip 添付
2. 解凍パスワードのみ

手順:

```bash
# 1. パスワード側メールを読んでパスワードを確認
python3 ~/.claude/skills/eml-read/scripts/eml-read.py mail2-password.eml

# 2. 本文側メールの zip 添付を、確認したパスワードで解凍
python3 ~/.claude/skills/eml-read/scripts/eml-read.py mail1-body.eml \
  --attach-dir /tmp/ppap --unzip-pw 'PASSWORD' --unzip-dir /tmp/ppap/extracted

# 3. 展開された中身を通常の Read tool で読む
```

- `--unzip-pw` は `--attach-dir` 併用必須 (zip を保存してから解凍)。
- `--unzip-dir` 省略時は `<zip 名>_extracted/` に展開。
- 誤パスワードは `Bad password` で失敗 (= 検知できる)。

## オプション

| flag | 用途 |
|---|---|
| `--attach-dir DIR` | 添付実体を保存 |
| `--unzip-pw PW` | 保存した zip 添付を PW で解凍 (PPAP 受領) |
| `--unzip-dir DIR` | 解凍先 (省略時 `<zip>_extracted/`) |
| `--raw-body` | text/html を生で出す (タグ除去しない) |

## 制約

- **AES 暗号化 zip** は標準 `zipfile` 非対応 → `Bad password` 類似エラー。
  その場合は `pip install pyzipper` して別途解凍 (PPAP の多くは ZipCrypto なので
  通常は標準 zipfile で足りる)。
- 暗号化 zip の**作成側** (PPAP 送付) は `zip -e -P 'PW' out.zip files...`。

## 関連

- ref-files から .eml を落とす: `ref-files-bulk` skill (`folder_download_url`)
- 一次資料例: ref-files `egov-shinsei-sdk-spec` `spec/*5370088*.eml`
