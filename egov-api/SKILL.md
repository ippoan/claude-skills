---
name: egov-api
description: >
  e-Gov 電子申請API の動作確認・デバッグ・実装支援スキル。
  OAuth2 認証フロー、申請案件一覧取得、申請状況確認などを実行できる。
  トリガー: 「e-Gov API」「電子申請API」「申請状況確認」「e-gov チェック」「egov」等。
---

# e-Gov 電子申請API

## サーバー

- 電子申請API: `https://api.e-gov.go.jp/shinsei/v2`
- 利用者認証: `https://account.e-gov.go.jp/auth`

## 認証フロー (OAuth2 Authorization Code Grant + PKCE)

1. **ユーザー認可** `GET https://account.e-gov.go.jp/auth/auth`
   - `client_id` = .env の `software_id`
   - `response_type` = `code`
   - `scope` = `openid offline_access`
   - `redirect_uri` = APIキー発行時に登録したURL
   - `state` = CSRF対策用ランダム値
   - `code_challenge` / `code_challenge_method` = `S256` (PKCE)

2. **リダイレクトで認可コード受信** (有効期限60秒)

3. **トークン取得** `POST https://account.e-gov.go.jp/auth/token`
   - Authorization: `Basic base64(software_id:API_KEY)`
   - Content-Type: `application/x-www-form-urlencoded`
   - Body: `grant_type=authorization_code&code=...&redirect_uri=...&code_verifier=...`
   - access_token有効期限: 1時間、refresh_token: 180日

4. **トークン再取得** 同エンドポイント、`grant_type=refresh_token`

5. **ログアウト** `POST https://account.e-gov.go.jp/auth/logout`

## .env

```
API_KEY=xxx    # OAuth2 client_secret
software_id=xxx  # OAuth2 client_id
```

## APIリクエスト共通ヘッダ

- `Authorization: Bearer {access_token}`
- `X-eGovAPI-Trial: true` (トライアル時)

## 主要エンドポイント

詳細は [references/api-endpoints.md](references/api-endpoints.md) を参照。

| パス | 説明 |
|------|------|
| `GET /apply/lists` | 申請案件一覧取得 |
| `GET /apply/{arrive_id}` | 申請案件詳細取得 |
| `GET /notice/lists` | 通知一覧 |
| `GET /message/lists` | ご案内一覧 |
| `POST /apply` | 申請データ送信 |

## OpenAPI仕様

完全な仕様: [references/openapi.json](references/openapi.json)
オンライン: https://developer.e-gov.go.jp/sites/default/files/filebrowser/e-gov/redoc/redoc-static.html
