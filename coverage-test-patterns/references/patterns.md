# Coverage Test Patterns Reference

## 1. DB Error Injection — Trigger Pattern

SELECT は成功するが INSERT/UPDATE だけ失敗させる。テーブル RENAME では SELECT も壊れるため、trigger が最適。

### BEFORE INSERT trigger (INSERT 拒否)

```rust
// 作成
sqlx::query(
    r#"CREATE OR REPLACE FUNCTION alc_api.reject_insert_fn() RETURNS trigger AS $$
       BEGIN RAISE EXCEPTION 'test: insert blocked'; END;
       $$ LANGUAGE plpgsql"#
).execute(&state.pool).await.unwrap();
sqlx::query(
    "CREATE TRIGGER reject_insert BEFORE INSERT ON alc_api.target_table FOR EACH ROW EXECUTE FUNCTION alc_api.reject_insert_fn()"
).execute(&state.pool).await.unwrap();

// テスト実行...

// 後片付け (trigger → function の順)
sqlx::query("DROP TRIGGER reject_insert ON alc_api.target_table")
    .execute(&state.pool).await.unwrap();
sqlx::query("DROP FUNCTION alc_api.reject_insert_fn()")
    .execute(&state.pool).await.unwrap();
```

### BEFORE UPDATE trigger (条件付き UPDATE 拒否)

特定フィールドの変更のみ拒否する場合:

```rust
sqlx::query(
    r#"CREATE OR REPLACE FUNCTION alc_api.reject_update_fn() RETURNS trigger AS $$
       BEGIN
         IF NEW.target_field IS DISTINCT FROM OLD.target_field THEN
           RAISE EXCEPTION 'test: update blocked';
         END IF;
         RETURN NEW;
       END;
       $$ LANGUAGE plpgsql"#
).execute(&state.pool).await.unwrap();
```

### BEFORE UPDATE trigger (値の改ざん)

UPDATE 自体は成功するが、値を壊して後続処理を失敗させる:

```rust
sqlx::query(
    r#"CREATE OR REPLACE FUNCTION alc_api.corrupt_field_fn() RETURNS trigger AS $$
       BEGIN
         IF NEW.status = 'completed' THEN
           NEW.r2_zip_key := 'corrupted-nonexistent-key';
         END IF;
         RETURN NEW;
       END;
       $$ LANGUAGE plpgsql"#
).execute(&state.pool).await.unwrap();
```

## 2. DB Error Injection — Table RENAME Pattern

JOIN クエリや SELECT 自体を失敗させる場合。`--test-threads=1` 必須。

```rust
// テーブルを一時リネーム (コミット済み)
sqlx::query("ALTER TABLE alc_api.target_table RENAME TO target_table_bak")
    .execute(&state.pool).await.unwrap();

// テスト実行 → query が失敗 → Err

// 後片付け
sqlx::query("ALTER TABLE alc_api.target_table_bak RENAME TO target_table")
    .execute(&state.pool).await.unwrap();
```

注意: PostgreSQL DDL はトランザクション内でも ROLLBACK 可能だが、別 connection からは見えない。コミット済み RENAME を使う場合は他テストに影響するため `--test-threads=1` で実行する。

## 3. Edge Case Data Patterns

### 列数不足データ

```rust
let short_csv = "h0,h1,h2\nshort,data,only\n";
let (bytes, _, _) = encoding_rs::SHIFT_JIS.encode(short_csv);
state.storage.upload(&key, &bytes, "text/csv").await.unwrap();
```

### パース失敗データ (正しい列数 + 不正値)

```rust
let bad_csv = "h0,h1,...,h10,h11\na,b,...,NOT_A_DATE,NOT_A_DATE\n";
```

### 不正 CSV 入り ZIP

```rust
fn create_zip_with_bad_csv() -> Vec<u8> {
    let bad_data = "this is not valid CSV\nno columns here\n";
    let (bytes, _, _) = encoding_rs::SHIFT_JIS.encode(bad_data);
    let mut buf = std::io::Cursor::new(Vec::new());
    {
        let mut zip = zip::ZipWriter::new(&mut buf);
        let opts = zip::write::SimpleFileOptions::default();
        zip.start_file("VALID.csv", opts).unwrap();
        zip.write_all(&valid_bytes).unwrap();
        zip.start_file("BAD.csv", opts).unwrap();
        zip.write_all(&bytes).unwrap();
        zip.finish().unwrap();
    }
    buf.into_inner()
}
```

### 非対象ファイル入り ZIP

```rust
zip.start_file("README.txt", opts).unwrap();
zip.write_all(b"This is not a CSV file").unwrap();
```

### 存在しない R2 キー

```rust
// DB に存在しないキーを登録 → download 失敗
sqlx::query("INSERT INTO upload_history (..., r2_zip_key) VALUES (..., 'nonexistent-key')")
    .execute(&mut *conn).await.unwrap();
// MockStorage には upload しない → download で NotFound
```

## 4. SSE Endpoint Testing

SSE は常に HTTP 200 を返す。エラーはイベントストリーム内:

```rust
let res = client.post(format!("{base_url}/api/sse-endpoint"))
    .header("Authorization", &auth)
    .send().await.unwrap();
assert_eq!(res.status(), 200); // SSE は常に 200
let body = res.text().await.unwrap();
assert!(body.contains("error"), "Should contain error event: {body}");
```

## 5. llvm-cov の閉じ括弧問題

nested `if` の閉じ `}` が別リージョンとしてカウントされ、内側のコードが実行されても外側の `}` が uncovered になる場合がある:

```rust
// BAD: llvm-cov で } が uncovered になりやすい
if outer_condition {
    if let Some(x) = inner_parse() {
        // ...
    }
}  // ← この } が uncovered

// GOOD: continue パターンで回避
if !outer_condition {
    continue;
}
if let Some(x) = inner_parse() {
    // ...
}
```

## 6. tracing マクロの複数行問題

`tracing::info!` 等を `cargo fmt` が複数行に展開すると、llvm-cov が引数行を未カバーと判定する:

```rust
// BAD: llvm-cov で引数行が uncovered
tracing::info!(
    "KUDGIVT parsed: {} rows (tenant={})",
    kudgivt_rows.len(),   // ← ^0 uncovered
    tenant_id             // ← ^0 uncovered
);

// GOOD: format! で事前結合 → tracing に1引数で渡す (cargo fmt 耐性あり)
let msg = format!("KUDGIVT parsed: {} rows (tenant={})", kudgivt_rows.len(), tenant_id);
tracing::info!("{msg}");
```

`format!` で事前結合すれば `cargo fmt` が展開しても tracing は1引数のままで未カバーにならない。
`#[rustfmt::skip]` は使わないこと — lint抑制よりテスト追加・コード変換で対応する。

## 6a. Option::filter フラット化パターン

nested `if let` + 条件で `Option` を処理すると、llvm-cov が閉じ括弧を未カバーにする:

```rust
// BAD: 閉じ括弧が uncovered
if let Some(tx) = &progress_tx {
    if some_condition {
        let _ = tx.send(msg).await;
    }
}  // ← uncovered

// GOOD: Option::filter でフラット化
if let Some(tx) = progress_tx.as_ref().filter(|_| some_condition) {
    let _ = tx.send(msg).await;
}
```

## 6b. .map() vs if let の行レベルカバレッジの罠

`.map()` チェーンは1行に収まるが `if let` は複数行になり、llvm-cov が閉じ括弧を別リージョンとして扱う:

```rust
// 注意: clippy が manual_map を指摘しても、if let に変換すると閉じ括弧が未カバーになる場合がある
// 元の .map() が1行でカバレッジ 100% なら、clippy::manual_map を修正する際は
// 閉じ括弧問題を意識してフラット化パターン (continue, Option::filter 等) を使うこと
```

## 7. カバレッジ専用テストの ignore 属性

```rust
// cargo test ではスキップ、cargo llvm-cov では実行
#[cfg_attr(not(coverage), ignore)]
#[tokio::test]
async fn test_error_path_for_coverage() {
    // DB エラー注入等
}
```

`Cargo.toml` に `cfg(coverage)` の許可が必要:
```toml
[lints.rust]
unexpected_cfgs = { level = "allow", check-cfg = ['cfg(coverage)'] }
```

## 8. Dead Code の判定と削除

到達不可能なコードを特定して削除:

- **SQL DISTINCT + HashSet 重複チェック**: SQL が DISTINCT を保証しているなら、コード側の重複チェックは不要
- **div-by-zero guard で分母が常に > 0**: `.max(1)` に簡素化
- **防御的 else**: `0.0` を返すだけの else ブランチは `.max(1)` 等で除去
