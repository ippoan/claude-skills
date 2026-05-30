---
name: backend-check
description: Rust バックエンドのコード品質チェック。DBエラー握りつぶし、旧テーブル名、RLS未設定、ストレージバケット不一致などを検出する
user_invocable: true
---

# Backend Check Agent

Rust バックエンドコードの品質・安全性チェックを実行する。

## チェック項目

### 1. DBエラー握りつぶし (`let _ =` on DB queries)
`let _ =` で sqlx クエリの Result を無視している箇所を検出。
エラーが握りつぶされると、テーブル名ミスやRLS違反が気づかれない。

```
検索パターン: let _ =.*sqlx|let _ =.*query.*execute|let _ =.*fetch
```

### 2. 旧テーブル名（スキーマプレフィックスなし）
`alc_api.` プレフィックスなしで dtako 関連テーブルを参照している箇所を検出。
移行時にコピペで旧テーブル名が残ることがある。

```
検索パターン（dtako関連ファイル内）:
- FROM operations[^_]  (→ alc_api.dtako_operations)
- FROM upload_history  (→ alc_api.dtako_upload_history)
- FROM daily_work_hours[^_]  (→ alc_api.dtako_daily_work_hours)
- FROM daily_work_segments  (→ alc_api.dtako_daily_work_segments)
- FROM scrape_history  (→ alc_api.dtako_scrape_history)
- FROM event_classifications  (→ alc_api.dtako_event_classifications)
- UPDATE operations  / INSERT INTO operations  等も同様
```

### 3. RLS 未設定アクセス
`set_current_tenant` を呼ばずに RLS 有効テーブルにアクセスしている関数を検出。
`state.pool` を直接使うと、コネクションごとに tenant が設定されないため RLS 違反になる。

```
検索パターン:
- &state.pool を直接 execute/fetch に渡している箇所（dtako 関連ファイル内）
- state.pool.acquire() + set_current_tenant のペアがない関数
```

### 4. ストレージバケット不一致
dtako 関連の R2 操作で `state.storage`（alc-face-photos）を使っている箇所を検出。
dtako データは `state.dtako_storage`（ohishi-dtako）を使うべき。

```
検索パターン（dtako 関連ファイル内）:
- state.storage.upload / state.storage.download
- ただし state.dtako_storage は正しい
```

### 5. uploaded_by に不適切な値
`uploaded_by` カラムに tenant_id を入れている箇所を検出。
スクレイパー等ユーザーなしのコンテキストでは NULL にすべき。

## 実行手順

1. 上記パターンを Grep で検索
2. 検出された箇所をファイル名・行番号付きで報告
3. 各項目の深刻度を表示:
   - 🔴 CRITICAL: DBエラー握りつぶし、旧テーブル名
   - 🟡 WARNING: RLS未設定、ストレージ不一致
   - 🔵 INFO: uploaded_by 確認推奨

## 対象ディレクトリ

- `/home/yhonda/rust/rust-alc-api/src/routes/dtako_*.rs`
- `/home/yhonda/rust/rust-alc-api/src/routes/mod.rs`（ルート登録確認）
