---
name: coverage-test-patterns
description: >
  Rust (Axum) プロジェクトでカバレッジ 100% を達成するためのテストパターン集。
  PostgreSQL (sqlx) 向け: DB エラー注入 (trigger / table RENAME)、エッジケースデータ生成、SSE テスト。
  SQL Server (tiberius + bb8) 向け: DB/ロジック分離、broken pool、Axum oneshot テスト。
  共通: llvm-cov の閉じ括弧問題回避、dead code 判定・削除の手法を提供する。
  トリガー: 「カバレッジ100%」「テストパターン」「エラー注入」「DB error injection」
  「未カバー行のテスト」「coverage 上げ」「テスト書いて」「エッジケーステスト」等。
---

# Coverage Test Patterns

Rust (Axum) プロジェクトのカバレッジ 100% 達成に使用する実証済みテストパターン。
PostgreSQL (sqlx) と SQL Server (tiberius + bb8) の両方に対応。

## ワークフロー

1. `/coverage-check --refresh --full --context <file>` で未カバー行を特定
2. 各行の未カバー理由を分類 → 対策選択
3. テストを一括作成 (中間カバレッジ確認しない)
4. `cargo test` 1回 → `/coverage-check --refresh --full <file>` 1回で確認

## 未カバー行の分類と対策

| 分類 | 例 | 対策 |
|------|---|------|
| DB エラーログ | `if let Err(e) = query.execute()` | trigger / RENAME パターン |
| エッジケースデータ | 列数不足、パース失敗 | 不正データを MockStorage/DB に配置 |
| 閉じ括弧 `}` | nested if の外側 `}` | `continue` リファクタで平坦化 |
| 到達不可能コード | SQL DISTINCT + HashSet 重複チェック | dead code 削除 |

### DB エラー注入

**重要: `pool.close()` は認証ありエンドポイントでは使えない。**
ミドルウェア (`require_tenant` → `set_current_tenant`) が先に DB 接続してエラーになり、ハンドラまで到達しない。
認証なし (public_router) のエンドポイントでのみ `pool.close()` が有効。

**trigger 方式** — SELECT は成功、INSERT/UPDATE/DELETE のみ失敗させる:
- `BEFORE INSERT trigger` → RAISE EXCEPTION
- `BEFORE UPDATE trigger` → RAISE EXCEPTION
- `BEFORE DELETE trigger` → RAISE EXCEPTION

**table RENAME 方式** — SELECT 自体を失敗させる (認証ありエンドポイントの SELECT エラーパス用):
- `ALTER TABLE ... RENAME TO ...` → リクエスト → `ALTER TABLE ... RENAME TO ...` (復元)
- **`DB_RENAME_LOCK` + `db_rename_flock()` 必須** (下記「テスト並列化」参照)

コード例: [references/patterns.md](references/patterns.md) セクション 1-2

### エッジケースデータ

- 列数不足 CSV / パース失敗データ / 不正 CSV in ZIP / 非 CSV in ZIP / 存在しない R2 キー

コード例: [references/patterns.md](references/patterns.md) セクション 3

### llvm-cov 閉じ括弧問題

```rust
// 修正前: } が uncovered
if cols.len() > 11 {
    if let (Some(a), Some(b)) = (...) { ... }
}  // ← uncovered

// 修正後
if cols.len() <= 11 { continue; }
if let (Some(a), Some(b)) = (...) { ... }
```

詳細: [references/patterns.md](references/patterns.md) セクション 5

## テスト構造テンプレート

### trigger パターン (INSERT/UPDATE/DELETE エラー)

```rust
#[cfg_attr(not(coverage), ignore)]
#[tokio::test]
async fn test_error_path_trigger() {
    let _db = common::DB_RENAME_LOCK.lock().unwrap();
    let _flock = common::db_rename_flock();
    let state = common::setup_app_state().await;
    let base_url = common::spawn_test_server(state.clone()).await;
    let tenant_id = common::create_test_tenant(&state.pool, "UniqueTestName").await;
    let jwt = common::create_test_jwt(tenant_id, "admin");
    let client = reqwest::Client::new();

    // Inject: trigger で INSERT を拒否
    sqlx::query(r#"CREATE OR REPLACE FUNCTION alc_api.fail_xxx() RETURNS trigger AS $$
        BEGIN RAISE EXCEPTION 'test error'; END; $$ LANGUAGE plpgsql"#)
        .execute(&state.pool).await.unwrap();
    sqlx::query("CREATE OR REPLACE TRIGGER fail_xxx BEFORE INSERT ON alc_api.target_table
        FOR EACH ROW EXECUTE FUNCTION alc_api.fail_xxx()")
        .execute(&state.pool).await.unwrap();

    let res = client.post(format!("{base_url}/api/..."))
        .header("Authorization", format!("Bearer {jwt}"))
        .json(&serde_json::json!({...}))
        .send().await.unwrap();
    assert_eq!(res.status(), 500);

    // Cleanup (MUST): trigger → function の順
    sqlx::query("DROP TRIGGER fail_xxx ON alc_api.target_table").execute(&state.pool).await.unwrap();
    sqlx::query("DROP FUNCTION alc_api.fail_xxx").execute(&state.pool).await.unwrap();
}
```

### RENAME パターン (SELECT エラー)

```rust
#[cfg_attr(not(coverage), ignore)]
#[tokio::test]
async fn test_error_path_rename() {
    let _db = common::DB_RENAME_LOCK.lock().unwrap();
    let _flock = common::db_rename_flock();
    let state = common::setup_app_state().await;
    let base_url = common::spawn_test_server(state.clone()).await;
    let tenant_id = common::create_test_tenant(&state.pool, "UniqueTestName").await;
    let jwt = common::create_test_jwt(tenant_id, "admin");
    let client = reqwest::Client::new();

    sqlx::query("ALTER TABLE alc_api.target_table RENAME TO target_table_bak")
        .execute(&state.pool).await.unwrap();

    let res = client.get(format!("{base_url}/api/..."))
        .header("Authorization", format!("Bearer {jwt}"))
        .send().await.unwrap();
    assert_eq!(res.status(), 500);

    // Cleanup (MUST)
    sqlx::query("ALTER TABLE alc_api.target_table_bak RENAME TO target_table")
        .execute(&state.pool).await.unwrap();
}
```

## カバレッジ専用テストの分離

`cargo llvm-cov` は `-C instrument-coverage` を渡すため、Rust 1.83+ では `cfg(coverage)` が自動で有効になる。
これを利用して、カバレッジ計測時のみ実行するテストを通常テストから分離できる。

### テストの分類

| 分類 | 属性 | `cargo test` | `cargo llvm-cov` |
|------|------|-------------|------------------|
| 通常テスト | なし | ✅ 実行 | ✅ 実行 |
| カバレッジ専用 | `#[cfg_attr(not(coverage), ignore)]` | ⏭ スキップ | ✅ 実行 |

### カバレッジ専用にすべきテスト

- エラーパスのみをカバーするテスト (DB error injection: trigger / RENAME)
- エッジケースデータのみのテスト (不正CSV、列数不足等)
- 閉じ括弧カバレッジのためだけのテスト
- `coverage_100_test.rs` のテスト全般

### カバレッジ専用にしてはいけないテスト

- 正常系の機能テスト (ビジネスロジックの検証)
- 新規エンドポイントの基本テスト (APIが動作することの確認)
- リグレッション防止を目的としたテスト

### 適用例

```rust
#[cfg_attr(not(coverage), ignore)]
#[tokio::test]
async fn test_daily_health_db_error() {
    // DB エラー注入テスト — カバレッジ計測時のみ実行
    test_group!("カバレッジ 100% 補完");
    test_case!("daily-health-status で DB エラー時に 500 を返す", {
        // ...
    });
}
```

### test_case! マクロの cfg(coverage) 透過

`test_case!` マクロは `#[cfg(coverage)]` で透過版に切り替わる:

```rust
// src/test_macros.rs / tests/common/test_macros.rs
#[cfg(coverage)]
macro_rules! test_case {
    ($desc:expr, $body:expr) => { $body };  // I/O なし
}

#[cfg(not(coverage))]
macro_rules! test_case {
    ($desc:expr, $body:expr) => {{
        print!("  ✅ {} ... ", $desc);
        std::io::Write::flush(&mut std::io::stdout()).ok();
        let val = $body;
        println!("OK");
        val
    }};
}
```

カバレッジ計測時は print!/flush が除去され、計測精度が向上する。

### Cargo.toml 設定

`cfg(coverage)` を使うには `unexpected_cfgs` の許可が必要:

```toml
[lints.rust]
unexpected_cfgs = { level = "allow", check-cfg = ['cfg(coverage)'] }
```

## 外部 API モック (wiremock)

外部 API (LINE WORKS, Google 等) のハッピーパスをテストするには `wiremock` でモックサーバーを立てる。

### セットアップ

```toml
# Cargo.toml
[dev-dependencies]
wiremock = "0.6"
```

### パターン: ハードコード URL を env var でオーバーライド可能にする

```rust
// src/auth/lineworks.rs — 本番コード側
fn token_url() -> String {
    std::env::var("LINEWORKS_TOKEN_URL")
        .unwrap_or_else(|_| "https://auth.worksmobile.com/oauth2/v2.0/token".to_string())
}
```

### テスト例

```rust
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[cfg_attr(not(coverage), ignore)]
#[tokio::test]
async fn test_lineworks_callback_happy_path() {
    let mock_server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/oauth2/v2.0/token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "access_token": "mock-token", "token_type": "Bearer", "expires_in": 3600
        })))
        .mount(&mock_server).await;

    Mock::given(method("GET"))
        .and(path("/v1.0/users/me"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "userId": "lw-user-001", "email": "test@example.com"
        })))
        .mount(&mock_server).await;

    std::env::set_var("LINEWORKS_TOKEN_URL", format!("{}/oauth2/v2.0/token", mock_server.uri()));
    std::env::set_var("LINEWORKS_USERINFO_URL", format!("{}/v1.0/users/me", mock_server.uri()));

    // ... テスト実行 ...

    // Cleanup
    std::env::remove_var("LINEWORKS_TOKEN_URL");
    std::env::remove_var("LINEWORKS_USERINFO_URL");
}
```

### エラーレスポンスのモック

```rust
// 外部 API エラー → 502 BAD_GATEWAY / 401 等をテスト
Mock::given(method("POST"))
    .and(path("/oauth2/v2.0/token"))
    .respond_with(ResponseTemplate::new(500).set_body_string("Internal Server Error"))
    .mount(&mock_server).await;
```

### SSO config テストデータ (AES-256-GCM 暗号化)

```rust
fn encrypt_test_secret(plaintext: &str, key_material: &str) -> String {
    use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
    use ring::rand::{SecureRandom, SystemRandom};
    let mut key_bytes = [0u8; 32];
    let hash = <sha2::Sha256 as sha2::Digest>::digest(key_material.as_bytes());
    key_bytes.copy_from_slice(&hash);
    let key = LessSafeKey::new(UnboundKey::new(&AES_256_GCM, &key_bytes).unwrap());
    let rng = SystemRandom::new();
    let mut nonce_bytes = [0u8; 12];
    rng.fill(&mut nonce_bytes).unwrap();
    let nonce = Nonce::assume_unique_for_key(nonce_bytes);
    let mut in_out = plaintext.as_bytes().to_vec();
    key.seal_in_place_append_tag(nonce, Aad::empty(), &mut in_out).unwrap();
    let mut data = nonce_bytes.to_vec();
    data.extend_from_slice(&in_out);
    base64::engine::general_purpose::STANDARD.encode(&data)
}
```

## テスト並列化

テストは `--test-threads=1` なしで並列実行可能。グローバル状態を変更するテストはロックで直列化する。

### ロック種別 (tests/common/mod.rs)

| ロック | スコープ | 用途 |
|--------|---------|------|
| `DB_RENAME_LOCK` (Mutex) | プロセス内 (同一バイナリ) | RENAME/trigger テスト同士の直列化 |
| `db_rename_flock()` (flock) | OS 全体 (バイナリ間) | 別テストバイナリ間の直列化 |
| `ENV_LOCK` (Mutex) | プロセス内 | `std::env::set_var` / `remove_var` の競合防止 |
| `GOOGLE_LOGIN_LOCK` (Mutex) | プロセス内 | `email_domain='example.com'` データ競合防止 |

### pool.close() の制限

**認証ありエンドポイントでは pool.close() は使えない。**
ミドルウェア (`require_tenant` → `set_current_tenant`) が先に DB 接続して失敗し、ハンドラの `map_err` まで到達しない。

認証なし (public_router) のエンドポイントでのみ pool.close() が有効:
```rust
let state = common::setup_app_state().await;
let base_url = common::spawn_test_server(state.clone()).await;
state.pool.close().await;
// 認証なしエンドポイントのみ OK
let res = client.post(format!("{base_url}/api/tenko-call/register"))...
```

### trigger / RENAME パターン (DB_RENAME_LOCK + flock 必須)

RENAME/trigger はスキーマ変更なので、**同時に走る全テストに影響**する。
`DB_RENAME_LOCK` はプロセス内 Mutex なので同一テストバイナリ内でしか効かない。
**バイナリ間の直列化には `db_rename_flock()` (ファイルロック) が必須。**

```rust
#[cfg_attr(not(coverage), ignore)]
#[tokio::test]
async fn test_xxx_db_error() {
    let _db = common::DB_RENAME_LOCK.lock().unwrap();  // プロセス内
    let _flock = common::db_rename_flock();              // バイナリ間
    // ... RENAME or trigger ...
}
```

**影響を受けるテーブルを使う他テスト (正常系含む) にも同じロックを追加すること。**
例: `communication_items` テーブルを RENAME するテストがある場合、
同テーブルを使う正常系テスト (`test_communication_items_get_by_id` 等) にもロック追加が必要。

### flock の仕組み (tests/common/mod.rs)

```rust
// libc crate (dev-dependencies) を使用
pub struct FileLockGuard(std::fs::File);

impl Drop for FileLockGuard {
    fn drop(&mut self) {
        use std::os::unix::io::AsRawFd;
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN); }
    }
}

pub fn db_rename_flock() -> FileLockGuard {
    use std::os::unix::io::AsRawFd;
    let path = format!("{}/target/.db-rename.lock", env!("CARGO_MANIFEST_DIR"));
    let file = std::fs::OpenOptions::new()
        .create(true).write(true).open(&path).expect("lock file");
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
    assert_eq!(rc, 0, "flock failed");
    FileLockGuard(file)
}
```

### env var テスト (ENV_LOCK 必須)

```rust
let _env = common::ENV_LOCK.lock().unwrap();
std::env::set_var("OAUTH_STATE_SECRET", "test-value");
// ... テスト ...
std::env::remove_var("OAUTH_STATE_SECRET");
```

### spawn_test_server_with_scraper

`TEST_SCRAPER_URL` env var の代わりにパラメータで渡す (並列安全):

```rust
let base_url = common::spawn_test_server_with_scraper(state.clone(), &mock_server.uri()).await;
```

## 注意事項

- **後片付け必須**: trigger は DROP TRIGGER → DROP FUNCTION の順
- **SSE テスト**: HTTP 200 は常に返る。エラーはボディ内 event stream で確認
- **Shift-JIS**: 日本語 CSV は `encoding_rs::SHIFT_JIS.encode()` でエンコード
- **tracing マクロ**: `tracing::debug!` 等の複数行展開は llvm-cov で未カバーになる。tracing subscriber を初期化しても内部の format 引数行はカバーされない。対策: デバッグ専用ログは削除が最善。本番必要なログは `format!` で事前結合して tracing に1引数で渡す (`let msg = format!(...); tracing::info!("{msg}");`)。`#[rustfmt::skip]` は使わない
- **unreachable `.map_err()`**: 静的データ (埋め込みフォント等) や `Response::builder()` (有効なヘッダ) のように実行時エラーが起こり得ない箇所は `.map_err(...)? ` → `.expect("理由")` に変換して dead branch を除去する
- **DB CHECK 制約で到達困難な match arm**: CHECK 制約を一時 DROP → 不正値 INSERT/UPDATE → テスト → 不正行を DELETE/UPDATE で戻す → 制約復元。`DB_RENAME_LOCK` + `db_rename_flock()` で保護すること。inline CHECK の制約名は auto-generated なので `pg_constraint` から動的取得:
  ```rust
  let name: String = sqlx::query_scalar(
      "SELECT conname FROM pg_constraint WHERE conrelid = 'alc_api.table'::regclass AND conname LIKE '%column%'"
  ).fetch_one(&pool).await.unwrap();
  sqlx::query(&format!("ALTER TABLE alc_api.table DROP CONSTRAINT {name}")).execute(&pool).await.unwrap();
  // ... 不正値 INSERT/UPDATE → テスト ...
  // cleanup: 不正行を戻す → ADD CONSTRAINT (既存行が違反すると失敗するため)
  ```
- **Result を返す必要がない関数**: 埋め込みフォント等で失敗し得ない場合、`Result<T, E>` → `T` に変更し、内部の `ok_or_else` → `expect` にして dead branch を除去

### DB RENAME デッドロック回避

`ALTER TABLE RENAME` は `AccessExclusiveLock` を取得する。テスト内のトランザクションで RENAME すると、
サーバー側の別コネクションが同じテーブルにアクセスしようとしてロック待ちになりハングする可能性がある。

**対策**: RENAME はトランザクション外で実行し、`DB_RENAME_LOCK` + `db_rename_flock()` で他テストと直列化する。

### worktree 並列作業時の注意

Agent tool で worktree を使って並列にテストを書く場合、**このスキルの全内容を各エージェントのプロンプトに含めること。**
特に以下を必ず伝える:
- pool.close() は認証ありエンドポイントで使えない
- trigger/RENAME パターンの使い分け
- DB_RENAME_LOCK + db_rename_flock() が必須
- 後片付け (DROP TRIGGER → DROP FUNCTION / RENAME BACK) が必須

## CI で単一テスト実行

`.github/workflows/single-test.yml` — ブランチ名駆動の単一テスト CI。

### 使い方

```bash
git push origin fix/test_communication_items_crud
```

ブランチ名の `fix/` 以降がテスト名パターンになり、そのテストだけ `cargo llvm-cov` で実行される。
DB (PostgreSQL サービスコンテナ) 付き。カバレッジ結果がログに出る。

### ワークフロー

1. worktree でテスト修正
2. `fix/test_xxx` ブランチを push
3. CI でテスト実行 + カバレッジ確認
4. OK なら main 向け PR 作成 → remote で merge

## SQL Server (tiberius + bb8) プロジェクト固有パターン

PostgreSQL (sqlx) と異なる点が多い。詳細は [references/ichibanboshi-patterns.md](references/ichibanboshi-patterns.md) 参照。

### 核心: DB/ロジック分離

`tiberius::Row` はテストコードで構築不可、SQL Server Docker は RAM 2GB 必要で CI 困難。
→ ハンドラを「DB 層」(Row → 中間構造体) と「ロジック層」(純粋関数) に分離し、ロジック層を単体テスト。

```rust
// DB 層: 薄い変換のみ (テスト対象外)
fn rows_to_raw(rows: &[Row]) -> Vec<RawData> { ... }

// ロジック層: 純粋関数 (テスト可能)
pub fn build_response(current: &[RawData], prev: &[RawData]) -> Vec<ResponseItem> { ... }
```

分離前 ~15% → **分離後 ~76%** (DB なしで到達可能)

### bb8 pool に close() がない

`bb8::Pool` は `sqlx::PgPool` と違い `close()` メソッドがない。
`pool.get()` エラーパスのテストには「壊れたプール」を `build_unchecked` で作成:

```rust
let manager = ConnectionManager::new(unreachable_config);
let pool = Pool::builder()
    .max_size(1)
    .connection_timeout(Duration::from_millis(50))
    .build_unchecked(manager);
```

### 認証ミドルウェアの有無を確認

ichibanboshi では Cloudflare Access で保護しており、アプリ層の認証ミドルウェアは未適用。
→ 全エンドポイントで broken pool アプローチが有効 (alc の `require_tenant` が DB を叩く問題がない)。

### Axum oneshot テスト

`tower::ServiceExt::oneshot` でフルサーバー不要のハンドラテスト。broken pool + oneshot で
pool.get() エラーパス、パラメータバリデーション (missing param → 400, SQL injection → 400) をカバー。

### DB 書き込みがないプロジェクト

trigger パターン (INSERT/UPDATE/DELETE 拒否) は不要。SELECT-only API では:
- `pool.get()` 失敗 → `SERVICE_UNAVAILABLE` (broken pool で検証)
- query/result エラー → `INTERNAL_SERVER_ERROR` (ロジック分離で大部分回避)
