# PDF比較スキル

2つのPDFファイルを比較し、内容が同一かどうかを判定します。
PDFにはタイムスタンプ・UUID・PDFIDなどの動的メタデータが含まれるため、これらを除外して比較します。

## 使い方

```
/compare-pdf <baseline.pdf> <target.pdf>
```

## 実行手順

1. ファイル存在確認
```bash
ls -la "$1" "$2"
file "$1" "$2"
```

2. ファイルサイズ比較
```bash
ls -la "$1" "$2"
```

3. 動的メタデータを正規化してSHA256比較
```bash
# 以下を正規化:
# - D:YYYYMMDDHHmmss+TZ'TZ' (PDF日時)
# - YYYY-MM-DDTHH:mm:ss+TZ:TZ (ISO8601日時)
# - uuid:xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (UUID)
# - <32桁の16進数> (PDF ID)

sed -E "s/D:[0-9]{14}\+[0-9]{2}'[0-9]{2}'/D:NORM/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+[0-9]{2}:[0-9]{2}/NORM/g; s/uuid:[0-9a-f-]{36}/uuid:NORM/g; s/<[0-9a-f]{32}>/<NORM>/g" "$1" > /tmp/pdf_cmp_baseline.pdf
sed -E "s/D:[0-9]{14}\+[0-9]{2}'[0-9]{2}'/D:NORM/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+[0-9]{2}:[0-9]{2}/NORM/g; s/uuid:[0-9a-f-]{36}/uuid:NORM/g; s/<[0-9a-f]{32}>/<NORM>/g" "$2" > /tmp/pdf_cmp_target.pdf

sha256sum /tmp/pdf_cmp_baseline.pdf /tmp/pdf_cmp_target.pdf
```

4. 結果判定
```bash
cmp /tmp/pdf_cmp_baseline.pdf /tmp/pdf_cmp_target.pdf && echo "✅ 内容同一（動的メタデータのみ異なる）" || echo "❌ 内容が異なります"
```

5. 異なる場合は差分位置を表示
```bash
# 差分がある場合
cmp -l /tmp/pdf_cmp_baseline.pdf /tmp/pdf_cmp_target.pdf | head -10
```

## 出力例

### 同一の場合
```
=== PDF比較結果 ===
baseline: /tmp/baseline.pdf (93361 bytes)
target:   /tmp/optimized.pdf (93361 bytes)
SHA256(normalized):
  baseline: 7c1fc9820c7354bccad5151562ad0d1cff07ec252f40f5f33363b98dc55653a4
  target:   7c1fc9820c7354bccad5151562ad0d1cff07ec252f40f5f33363b98dc55653a4
✅ 内容同一（動的メタデータのみ異なる）
```

### 異なる場合
```
=== PDF比較結果 ===
baseline: /tmp/baseline.pdf (93361 bytes)
target:   /tmp/broken.pdf (85000 bytes)
❌ 内容が異なります
差分位置: byte 12345, line 100
```
