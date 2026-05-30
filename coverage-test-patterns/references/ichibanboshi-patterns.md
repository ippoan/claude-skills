# Coverage Test Patterns — SQL Server (tiberius + bb8)

rust-ichibanboshi 固有のカバレッジテストパターン。
PostgreSQL (sqlx) プロジェクトとは DB エラー注入の手法が根本的に異なる。

## 0. alc (PostgreSQL) との主要な違い

| 項目 | alc (PostgreSQL) | ichibanboshi (SQL Server) |
|------|-----------------|--------------------------|
| DB pool | `sqlx::PgPool` (`close()` あり) | `bb8::Pool` (`close()` **なし**) |
| エラー注入 | trigger / RENAME | broken pool (`build_unchecked`) |
| 認証 MW | `require_tenant` が DB アクセス | **未適用** (CF Access で保護) |
| DB 書き込み | INSERT/UPDATE/DELETE あり | **SELECT のみ** |
| Row 構築 | 不可 | 不可 (`tiberius::Row` も同様) |
| CI DB | PostgreSQL service container | SQL Server Docker は RAM 2GB 必要で CI 困難 |
| テスト戦略 | 実 DB (PostgreSQL) 前提 | **DB/ロジック分離** でロジック層を純粋関数テスト |

## 1. 核心: DB/ロジック分離パターン

### 問題

`tiberius::Row` はコンストラクタが非公開で、テストコードから構築できない。
SQL Server Docker は RAM 2GB 最低要件で GitHub Actions standard runner では厳しい。

→ **ハンドラを「DB 層」と「ロジック層」に分離し、ロジック層を純粋関数としてテストする。**

### リファクタリング前 (現状)

```rust
// sales.rs — DB アクセスとロジックが密結合
pub async fn monthly(
    Extension(pool): Extension<DbPool>,
    Query(params): Query<MonthlyQuery>,
) -> Result<Json<ApiResponse<Vec<MonthlySales>>>, StatusCode> {
    let mut conn = pool.get().await.map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    let stream = conn.query(sql, &[...]).await.map_err(|e| { ... })?;
    let rows = stream.into_first_result().await.map_err(|e| { ... })?;

    // ↓ ここからがロジック (tiberius::Row に依存)
    let mut prev_map = HashMap::new();
    for row in &prev_rows {
        let dt: NaiveDateTime = row.get(0).unwrap_or_default();
        let own = get_i64(row, 1);
        // ...
    }
    let data: Vec<MonthlySales> = rows.iter().map(|row| { ... }).collect();
    Ok(Json(ApiResponse { source_table, data }))
}
```

### リファクタリング後

```rust
// ── DB 層: Row → 中間構造体 (薄い変換のみ) ──

/// DB から取得した生データ (テスト不要 — 単純な型変換のみ)
pub struct RawMonthlyRow {
    pub year_month: NaiveDateTime,
    pub own_sales: i64,
    pub charter_sales: i64,
    pub transport_count: i32,
}

fn rows_to_raw_monthly(rows: &[Row]) -> Vec<RawMonthlyRow> {
    rows.iter().map(|row| RawMonthlyRow {
        year_month: row.get(0).unwrap_or_default(),
        own_sales: get_i64(row, 1),
        charter_sales: get_i64(row, 2),
        transport_count: get_i32(row, 3),
    }).collect()
}

// ── ロジック層: 純粋関数 (テスト可能) ──

/// 当期 + 前年データから MonthlySales を組み立てる
pub fn build_monthly_sales(
    current: &[RawMonthlyRow],
    prev: &[RawMonthlyRow],
) -> Vec<MonthlySales> {
    let mut prev_map = HashMap::new();
    for r in prev {
        let month = r.year_month.format("%m").to_string();
        prev_map.insert(month, (r.own_sales, r.charter_sales));
    }

    current.iter().map(|r| {
        let month = r.year_month.format("%m").to_string();
        MonthlySales {
            year_month: r.year_month.format("%Y-%m").to_string(),
            own_sales: r.own_sales,
            charter_sales: r.charter_sales,
            total_sales: r.own_sales + r.charter_sales,
            transport_count: r.transport_count,
            prev_year_own: prev_map.get(&month).map(|v| v.0).unwrap_or(0),
            prev_year_charter: prev_map.get(&month).map(|v| v.1).unwrap_or(0),
            prev_year_total: prev_map.get(&month).map(|v| v.0 + v.1).unwrap_or(0),
        }
    }).collect()
}

// ── ハンドラ: DB 層 + ロジック層の組み合わせ ──

pub async fn monthly(
    Extension(pool): Extension<DbPool>,
    Query(params): Query<MonthlyQuery>,
) -> Result<Json<ApiResponse<Vec<MonthlySales>>>, StatusCode> {
    let mut conn = pool.get().await.map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    // ... query ...
    let current = rows_to_raw_monthly(&rows);
    let prev = rows_to_raw_monthly(&prev_rows);
    let data = build_monthly_sales(&current, &prev);
    Ok(Json(ApiResponse { source_table, data }))
}
```

### テスト (DB 不要)

```rust
#[test]
fn test_build_monthly_sales_basic() {
    let current = vec![
        RawMonthlyRow {
            year_month: NaiveDate::from_ymd_opt(2025, 4, 1).unwrap().and_hms_opt(0, 0, 0).unwrap(),
            own_sales: 1_000_000,
            charter_sales: 500_000,
            transport_count: 50,
        },
        RawMonthlyRow {
            year_month: NaiveDate::from_ymd_opt(2025, 5, 1).unwrap().and_hms_opt(0, 0, 0).unwrap(),
            own_sales: 1_200_000,
            charter_sales: 600_000,
            transport_count: 55,
        },
    ];
    let prev = vec![
        RawMonthlyRow {
            year_month: NaiveDate::from_ymd_opt(2024, 4, 1).unwrap().and_hms_opt(0, 0, 0).unwrap(),
            own_sales: 900_000,
            charter_sales: 400_000,
            transport_count: 45,
        },
    ];

    let result = build_monthly_sales(&current, &prev);

    assert_eq!(result.len(), 2);
    assert_eq!(result[0].year_month, "2025-04");
    assert_eq!(result[0].total_sales, 1_500_000);
    assert_eq!(result[0].prev_year_total, 1_300_000); // 900k + 400k
    // 5月は前年データなし → 0
    assert_eq!(result[1].prev_year_total, 0);
}

#[test]
fn test_build_monthly_sales_empty() {
    let result = build_monthly_sales(&[], &[]);
    assert!(result.is_empty());
}

#[test]
fn test_build_monthly_sales_no_prev() {
    let current = vec![RawMonthlyRow { /* ... */ }];
    let result = build_monthly_sales(&current, &[]);
    assert_eq!(result[0].prev_year_own, 0);
    assert_eq!(result[0].prev_year_charter, 0);
}
```

### 分離対象の全エンドポイント

| エンドポイント | ロジック関数 | テスト観点 |
|--------------|------------|-----------|
| monthly | `build_monthly_sales()` | 前年マッチ、前年なし月、exclude_dept |
| by_department | `build_department_sales()` | ソート順、集計 |
| by_customer | `build_customer_sales()` | limit、集計 |
| customer_yoy | `build_customer_yoy()` | YoY%計算、min_prev フィルタ、正/負分離、ソート |
| yoy | `build_yoy_comparison()` | diff_percent 計算、前年 0 の場合 |
| daily | `build_daily_sales()` | 曜日計算、前年同日マッチ、billing/non_billing |
| customer_trend | `build_customer_trend()` | 順位計算、上位N社、空月 |
| customer_detail | (シンプル — 分離不要かも) | — |

### カバレッジ効果

| 部分 | 行数(概算) | DB なしテスト可能? |
|------|----------|-----------------|
| ロジック層 (build_*) | ~500行 | **Yes** (純粋関数) |
| DB 層 (rows_to_raw_*) | ~80行 | No (tiberius::Row) |
| pool.get() + query | ~200行 | pool.get() のみ (broken pool) |
| パラメータ解析 | ~100行 | Yes (ロジック層に含める) |

**DB なしで ~60% カバー可能** (分離前の ~15% から大幅改善)

## 2. broken pool パターン (pool.get() エラー)

`bb8::Pool::builder().build_unchecked()` で接続テストをスキップし、
接続不能な設定のプールを作成する。`pool.get().await` が必ず失敗する。

```rust
use bb8::Pool;
use bb8_tiberius::ConnectionManager;
use tiberius::Config as TiberiusConfig;

pub fn create_broken_pool() -> DbPool {
    let mut config = TiberiusConfig::new();
    config.host("127.0.0.1");
    config.port(1); // 何もリッスンしていないポート
    config.authentication(tiberius::AuthMethod::sql_server("x", "x"));
    config.encryption(tiberius::EncryptionLevel::NotSupported);
    let manager = ConnectionManager::new(config);
    Pool::builder()
        .max_size(1)
        .connection_timeout(std::time::Duration::from_millis(50))
        .build_unchecked(manager)
}
```

これにより各ハンドラの以下のパスがカバーされる:

```rust
let mut conn = pool.get().await.map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
```

## 3. Axum oneshot テスト (フルサーバー不要)

`tower::ServiceExt::oneshot` を使い、TCP リスナーなしでハンドラをテストする。
broken pool と組み合わせてエラーパスをカバー:

```rust
use axum::{routing::get, Extension, Router};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt; // oneshot

#[tokio::test]
async fn test_health_db_error() {
    let pool = create_broken_pool();
    let app = Router::new()
        .route("/health", get(rust_ichibanboshi::routes::health::health))
        .layer(Extension(pool));

    let req = Request::builder()
        .uri("/health")
        .body(Body::empty())
        .unwrap();

    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
}
```

### build_app ヘルパー

全ルートを含むアプリを構築するヘルパーを `tests/common/mod.rs` に用意:

```rust
pub fn build_app(pool: DbPool) -> Router {
    let jwt_secret = JwtSecret(TEST_JWT_SECRET.to_string());

    let api_routes = Router::new()
        .route("/sales/monthly", get(routes::sales::monthly))
        .route("/sales/by-department", get(routes::sales::by_department))
        .route("/sales/by-customer", get(routes::sales::by_customer))
        .route("/sales/yoy", get(routes::sales::yoy))
        .route("/sales/daily", get(routes::sales::daily))
        .route("/sales/customer-trend", get(routes::sales::customer_trend))
        .route("/sales/customer-yoy", get(routes::sales::customer_yoy))
        .route("/sales/customer-detail", get(routes::sales::customer_detail));

    let schema_routes = Router::new()
        .route("/schema/tables", get(routes::schema::list_tables))
        .route("/schema/columns", get(routes::schema::list_columns))
        .route("/schema/sample", get(routes::schema::sample_data));

    Router::new()
        .route("/health", get(routes::health::health))
        .nest("/api", api_routes)
        .nest("/api", schema_routes)
        .layer(Extension(pool))
        .layer(Extension(jwt_secret))
}
```

### 全エンドポイントの pool.get() エラーテスト

```rust
#[tokio::test]
async fn test_all_endpoints_db_error() {
    let pool = create_broken_pool();
    let app = build_app(pool);

    let endpoints = vec![
        "/health",
        "/api/schema/tables",
        "/api/schema/columns?table=test",
        "/api/schema/sample?table=test",
        "/api/sales/monthly",
        "/api/sales/by-department",
        "/api/sales/by-customer",
        "/api/sales/yoy",
        "/api/sales/daily",
        "/api/sales/customer-trend",
        "/api/sales/customer-yoy",
        "/api/sales/customer-detail?code=000001",
    ];

    for uri in endpoints {
        let req = Request::builder()
            .uri(uri)
            .body(Body::empty())
            .unwrap();
        let res = app.clone().oneshot(req).await.unwrap();
        assert_eq!(
            res.status(),
            StatusCode::SERVICE_UNAVAILABLE,
            "Expected 503 for {uri}"
        );
    }
}
```

## 4. パラメータ解析ロジックの分離

日付パラメータの解析・前年計算もロジック層に分離してテスト可能にする:

```rust
/// 月文字列 "2025-04" から前年の期間を計算
pub fn calc_prev_period(from: &str, to: &str) -> (String, String) {
    let prev_from = format!(
        "{}-{}-01",
        from.split('-').next().unwrap_or("2024").parse::<i32>().unwrap_or(2024) - 1,
        from.split('-').nth(1).unwrap_or("04")
    );
    let prev_to = format!(
        "{}-{}-01",
        to.split('-').next().unwrap_or("2025").parse::<i32>().unwrap_or(2025) - 1,
        to.split('-').nth(1).unwrap_or("03")
    );
    (prev_from, prev_to)
}

/// customer_yoy の月数計算
pub fn calc_months(from: &str, to: &str) -> i64 {
    let from_parts: Vec<&str> = from.split('-').collect();
    let to_parts: Vec<&str> = to.split('-').collect();
    let from_y = from_parts[0].parse::<i32>().unwrap_or(2025);
    let from_m = from_parts.get(1).and_then(|s| s.parse::<i32>().ok()).unwrap_or(4);
    let to_y = to_parts[0].parse::<i32>().unwrap_or(2026);
    let to_m = to_parts.get(1).and_then(|s| s.parse::<i32>().ok()).unwrap_or(3);
    ((to_y - from_y) * 12 + (to_m - from_m) + 1).max(1) as i64
}
```

### テスト

```rust
#[test]
fn test_calc_prev_period() {
    let (from, to) = calc_prev_period("2025-04", "2026-03");
    assert_eq!(from, "2024-04-01");
    assert_eq!(to, "2025-03-01");
}

#[test]
fn test_calc_months() {
    assert_eq!(calc_months("2025-04", "2026-03"), 12);
    assert_eq!(calc_months("2025-04", "2025-04"), 1);
    assert_eq!(calc_months("2025-01", "2025-06"), 6);
}
```

## 5. customer_yoy ロジックの分離例 (複雑なソート)

`customer_yoy` は YoY% 計算 + positive/negative 分離 + ソートロジックがあり、
分離の効果が最も大きい:

```rust
/// YoY エントリを計算
pub fn calc_yoy_entries(
    cur_map: &HashMap<String, (String, i64)>,  // code -> (name, total)
    prev_map: &HashMap<String, (String, i64)>,
    min_prev: i64,
) -> Vec<CustomerYoy> {
    let mut all_codes: HashSet<String> = cur_map.keys().cloned().collect();
    all_codes.extend(prev_map.keys().cloned());

    all_codes.into_iter().filter_map(|code| {
        let (cur_name, cur_total) = cur_map.get(&code).cloned().unwrap_or_default();
        let (prev_name, prev_total) = prev_map.get(&code).cloned().unwrap_or_default();
        let name = if !cur_name.is_empty() { cur_name } else { prev_name };

        if prev_total < min_prev { return None; }

        let diff = cur_total - prev_total;
        let pct = (diff as f64 / prev_total as f64) * 100.0;
        let pct = (pct * 10.0).round() / 10.0;

        Some(CustomerYoy { customer_code: code, customer_name: name, current_total: cur_total, prev_total, diff, yoy_percent: pct })
    }).collect()
}

/// positive/negative に分割しソート
pub fn split_and_sort_yoy(entries: Vec<CustomerYoy>, limit: usize) -> (Vec<CustomerYoy>, Vec<CustomerYoy>) {
    let mut pos: Vec<_> = entries.iter().filter(|e| e.yoy_percent > 0.0).cloned().collect();
    pos.sort_by(|a, b| b.prev_total.cmp(&a.prev_total));

    let mut neg: Vec<_> = entries.iter().filter(|e| e.yoy_percent < 0.0).cloned().collect();
    neg.sort_by(|a, b| {
        a.yoy_percent.partial_cmp(&b.yoy_percent).unwrap_or(std::cmp::Ordering::Equal)
            .then(b.prev_total.cmp(&a.prev_total))
    });

    (pos.into_iter().take(limit).collect(), neg.into_iter().take(limit).collect())
}
```

### テスト

```rust
#[test]
fn test_calc_yoy_entries_min_prev_filter() {
    let mut cur = HashMap::new();
    cur.insert("A".into(), ("顧客A".into(), 1_200_000));
    cur.insert("B".into(), ("顧客B".into(), 500_000));

    let mut prev = HashMap::new();
    prev.insert("A".into(), ("顧客A".into(), 1_000_000));
    prev.insert("B".into(), ("顧客B".into(), 30_000)); // min_prev 未満

    let entries = calc_yoy_entries(&cur, &prev, 40_000);
    assert_eq!(entries.len(), 1); // B は除外
    assert_eq!(entries[0].yoy_percent, 20.0); // (1.2M - 1M) / 1M * 100
}

#[test]
fn test_split_and_sort_yoy() {
    let entries = vec![
        CustomerYoy { customer_code: "A".into(), customer_name: "A".into(), current_total: 120, prev_total: 100, diff: 20, yoy_percent: 20.0 },
        CustomerYoy { customer_code: "B".into(), customer_name: "B".into(), current_total: 80, prev_total: 100, diff: -20, yoy_percent: -20.0 },
        CustomerYoy { customer_code: "C".into(), customer_name: "C".into(), current_total: 50, prev_total: 200, diff: -150, yoy_percent: -75.0 },
    ];

    let (pos, neg) = split_and_sort_yoy(entries, 10);
    assert_eq!(pos.len(), 1);
    assert_eq!(neg.len(), 2);
    assert_eq!(neg[0].customer_code, "C"); // -75% が先 (昇順)
    assert_eq!(neg[1].customer_code, "B"); // -20%
}

#[test]
fn test_yoy_percent_zero_prev() {
    // prev_total == 0 は min_prev フィルタで除外される
    let mut cur = HashMap::new();
    cur.insert("NEW".into(), ("新規".into(), 500_000));
    let prev = HashMap::new(); // 前年なし

    let entries = calc_yoy_entries(&cur, &prev, 1);
    assert!(entries.is_empty()); // prev_total=0 < min_prev=1
}
```

## 6. Unit テスト可能なコード (DB 不要、分離不要)

### 6a. config.rs — TOML パース + デフォルト値

```rust
#[test]
fn test_config_defaults() {
    let config: Config = toml::from_str("").unwrap();
    assert_eq!(config.port, 3100);
    assert_eq!(config.bind_addr, "127.0.0.1");
    assert_eq!(config.database.host, "localhost");
    assert_eq!(config.database.instance, "softec");
    assert_eq!(config.database.database, "CAPE#01");
    assert!(config.database.trust_server_certificate);
}

#[test]
fn test_config_full_toml() {
    let toml_str = r#"
port = 8080
bind_addr = "0.0.0.0"
[database]
host = "192.168.1.1"
instance = "MSSQL"
database = "TestDB"
user = "sa"
password = "secret"
port = 1433
trust_server_certificate = false
[auth]
jwt_secret = "my-secret"
[cors]
allowed_origins = ["http://localhost:3000"]
"#;
    let config: Config = toml::from_str(toml_str).unwrap();
    assert_eq!(config.port, 8080);
    assert_eq!(config.database.port, Some(1433));
    assert!(!config.database.trust_server_certificate);
    assert_eq!(config.auth.jwt_secret, "my-secret");
}

#[test]
fn test_config_addr() {
    let config: Config = toml::from_str("port = 9999\nbind_addr = \"0.0.0.0\"").unwrap();
    assert_eq!(config.addr(), "0.0.0.0:9999");
}

#[test]
fn test_config_from_args_override() {
    let args = AppArgs {
        console: true,
        config: None,
        port: Some(9999),
        bind_addr: Some("0.0.0.0".to_string()),
    };
    let config = Config::from_args_and_file(&args).unwrap();
    assert_eq!(config.port, 9999);
    assert_eq!(config.bind_addr, "0.0.0.0");
}

#[test]
fn test_config_file_not_found() {
    let args = AppArgs {
        console: true,
        config: Some("/nonexistent/path.toml".to_string()),
        port: None,
        bind_addr: None,
    };
    assert!(Config::from_args_and_file(&args).is_err());
}
```

### 6b. auth.rs — JWT 検証

```rust
use jsonwebtoken::{encode, EncodingKey, Header};
use chrono::Utc;
use uuid::Uuid;

const TEST_SECRET: &str = "test-jwt-secret-ichibanboshi";

fn create_test_jwt(tenant_id: Uuid, role: &str) -> String {
    let claims = AppClaims {
        sub: Uuid::new_v4(),
        email: "test@example.com".to_string(),
        name: "Test User".to_string(),
        tenant_id,
        role: role.to_string(),
        org_slug: None,
        iat: Utc::now().timestamp(),
        exp: Utc::now().timestamp() + 3600,
    };
    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(TEST_SECRET.as_bytes()),
    )
    .unwrap()
}

#[test]
fn test_verify_valid_token() {
    let secret = JwtSecret(TEST_SECRET.to_string());
    let token = create_test_jwt(Uuid::new_v4(), "admin");
    let claims = verify_access_token(&token, &secret).unwrap();
    assert_eq!(claims.email, "test@example.com");
}

#[test]
fn test_verify_wrong_secret() {
    let secret = JwtSecret("wrong-secret".to_string());
    let token = create_test_jwt(Uuid::new_v4(), "admin");
    assert!(verify_access_token(&token, &secret).is_err());
}

#[test]
fn test_verify_expired_token() {
    let secret = JwtSecret(TEST_SECRET.to_string());
    let claims = AppClaims {
        sub: Uuid::new_v4(),
        email: "test@example.com".to_string(),
        name: "Test".to_string(),
        tenant_id: Uuid::new_v4(),
        role: "admin".to_string(),
        org_slug: None,
        iat: Utc::now().timestamp() - 7200,
        exp: Utc::now().timestamp() - 3600,
    };
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(TEST_SECRET.as_bytes()),
    )
    .unwrap();
    assert!(verify_access_token(&token, &secret).is_err());
}

#[test]
fn test_verify_malformed_token() {
    let secret = JwtSecret(TEST_SECRET.to_string());
    assert!(verify_access_token("not-a-jwt", &secret).is_err());
    assert!(verify_access_token("", &secret).is_err());
}
```

### 6c. require_jwt ミドルウェア (oneshot テスト)

```rust
fn build_auth_test_app() -> Router {
    Router::new()
        .route("/test", get(|| async { "ok" }))
        .layer(middleware::from_fn(require_jwt))
        .layer(Extension(JwtSecret(TEST_SECRET.to_string())))
}

#[tokio::test]
async fn test_require_jwt_no_header() {
    let app = build_auth_test_app();
    let req = Request::builder().uri("/test").body(Body::empty()).unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_require_jwt_invalid_token() {
    let app = build_auth_test_app();
    let req = Request::builder()
        .uri("/test")
        .header("Authorization", "Bearer invalid-token")
        .body(Body::empty())
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_require_jwt_not_bearer() {
    let app = build_auth_test_app();
    let req = Request::builder()
        .uri("/test")
        .header("Authorization", "Basic dXNlcjpwYXNz")
        .body(Body::empty())
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_require_jwt_valid_token() {
    let app = build_auth_test_app();
    let token = create_test_jwt(Uuid::new_v4(), "admin");
    let req = Request::builder()
        .uri("/test")
        .header("Authorization", format!("Bearer {token}"))
        .body(Body::empty())
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
}
```

## 7. schema.rs バリデーションテスト (DB 不要)

```rust
#[tokio::test]
async fn test_schema_columns_missing_table_param() {
    let pool = create_broken_pool();
    let app = build_app(pool);
    let req = Request::builder()
        .uri("/api/schema/columns") // ?table= なし → 400
        .body(Body::empty()).unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_schema_sample_invalid_table_name() {
    let pool = create_broken_pool();
    let app = build_app(pool);
    let req = Request::builder()
        .uri("/api/schema/sample?table=foo;DROP%20TABLE") // SQL injection → 400
        .body(Body::empty()).unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}
```

## 8. プロジェクト準備

### lib.rs の作成

integration テストからモジュールを `use` するには `lib.rs` が必要:

```rust
// src/lib.rs
pub mod auth;
pub mod config;
pub mod db;
pub mod routes;
```

### Cargo.toml dev-dependencies

```toml
[dev-dependencies]
tower = { version = "0.5", features = ["util"] }  # ServiceExt::oneshot

[lints.rust]
unexpected_cfgs = { level = "allow", check-cfg = ['cfg(coverage)'] }
```

### tests/common/mod.rs

```rust
pub const TEST_JWT_SECRET: &str = "test-jwt-secret-ichibanboshi";

pub fn create_broken_pool() -> rust_ichibanboshi::db::DbPool { /* セクション 2 参照 */ }
pub fn build_app(pool: rust_ichibanboshi::db::DbPool) -> axum::Router { /* セクション 3 参照 */ }
pub fn create_test_jwt(tenant_id: uuid::Uuid, role: &str) -> String { /* セクション 6b 参照 */ }
```

## 9. カバレッジ見積もり

### DB/ロジック分離 + broken pool (DB 不要)

| 部分 | 行数(概算) | テスト可能? |
|------|----------|-----------|
| ロジック層 (build_* + calc_*) | ~500行 | **Yes** — 純粋関数 |
| config.rs | ~150行 | **Yes** — TOML パース |
| auth.rs | ~85行 | **Yes** — JWT + MW |
| schema バリデーション | ~20行 | **Yes** — パラメータ検証 |
| pool.get() エラーパス | ~30行 | **Yes** — broken pool |
| DB 層 (rows_to_raw_*) | ~80行 | No — tiberius::Row |
| query 実行 + エラーハンドラ | ~100行 | No — 実 DB 必要 |
| server.rs / main.rs / db.rs | ~200行 | No — 起動・接続 |
| **合計** | **~1033行** | **~785行 (~76%)** |

**分離前 ~15% → 分離後 ~76%** (DB なしで到達可能)

## 10. Windows service.rs について

`service.rs` は `#[cfg(windows)]` のため Linux ビルドに含まれず、カバレッジ対象外。
