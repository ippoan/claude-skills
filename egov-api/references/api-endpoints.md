# e-Gov 電子申請API エンドポイント一覧

ベースURL: `https://api.e-gov.go.jp/shinsei/v2`

## 電子申請

| メソッド | パス | 説明 |
|---------|------|------|
| GET | `/procedure/{proc_id}` | 手続選択（スケルトン取得） |
| POST | `/preprint` | プレ印字データ取得 |
| POST | `/apply` | 申請データ送信 |
| POST | `/bulk-apply` | 申請データbulk送信 |
| POST | `/apply/amend` | 補正データ送信 |
| POST | `/apply/withdraw` | 取り下げ依頼 |
| POST | `/apply/check` | 形式チェック実行 |
| GET | `/apply/lists` | 申請案件一覧取得 |
| GET | `/apply/{arrive_id}` | 申請案件詳細取得 |
| GET | `/apply/report` | エラーレポート取得 |

## 通知・メッセージ

| メソッド | パス | 説明 |
|---------|------|------|
| GET | `/message/lists` | 手続に関するご案内一覧 |
| GET | `/message/{information_id}` | ご案内詳細 |
| GET | `/notice/lists` | 申請案件に関する通知一覧 |
| GET | `/notice/{arrive_id}/{notice_sub_id}` | 通知詳細 |

## 公文書

| メソッド | パス | 説明 |
|---------|------|------|
| GET | `/official_document/{arrive_id}/{notice_sub_id}` | 公文書取得 |
| POST | `/official_document` | 公文書取得完了 |
| POST | `/official_document/verify` | 公文書署名検証 |

## 電子納付

| メソッド | パス | 説明 |
|---------|------|------|
| GET | `/payment/lists` | 金融機関一覧取得 |
| GET | `/payment/{arrive_id}` | 電子納付情報一覧取得 |
| POST | `/payment` | 電子納付金融機関サイト表示 |

## 電子送達

| メソッド | パス | 説明 |
|---------|------|------|
| POST | `/post-apply` | 電子送達利用申込み |
| GET | `/post-apply/{arrive_id}` | 電子送達状況確認 |
| GET | `/post/lists` | 電子送達一覧取得 |
| GET | `/post/{post_id}` | 電子送達取得 |
| POST | `/post` | 電子送達取得完了 |

## アカウント間情報共有

| メソッド | パス | 説明 |
|---------|------|------|
| GET | `/share-setting/lists` | 情報共有一覧取得 |
| POST | `/share-setting` | 情報共有設定 |
| PUT | `/share-setting` | 情報共有更新 |
| DELETE | `/share-setting` | 情報共有解除 |
| POST | `/share-confirmation` | 共有設定確認 |

## 利用者認証 (ベースURL: `https://account.e-gov.go.jp/auth`)

| メソッド | パス | 説明 |
|---------|------|------|
| GET | `/auth` | ユーザー認可 |
| POST | `/token` | アクセストークン取得/再取得 |
| POST | `/token/introspect` | アクセストークン検証 |
| POST | `/logout` | ログアウト |

## `/apply/lists` パラメータ

| パラメータ | 場所 | 必須 | 説明 |
|-----------|------|------|------|
| Authorization | header | ○ | `Bearer {access_token}` |
| X-eGovAPI-Trial | header | × | `true` でトライアル |
| send_number | query | △ | 送信番号 |
| date_from | query | △ | 対象期間開始日 (YYYY-MM-DD) |
| date_to | query | △ | 対象期間終了日 (YYYY-MM-DD) |
| limit | query | × | 取得件数 (max 50) |
| offset | query | × | オフセット |

※ send_number のみ指定 または date_from/date_to 指定

## `/apply/lists` レスポンス例

```json
{
  "metadata": {
    "title": "申請案件一覧取得API",
    "detail": "正常に処理が完了しました。",
    "type": "...",
    "instance": "/apply/lists"
  },
  "resultset": {
    "all_count": 10,
    "limit": 50,
    "offset": 0,
    "count": 10
  },
  "results": {
    "apply_list": [
      {
        "no": 1,
        "send_number": "123456789012345678",
        "send_date": "2024-01-15 09:30:00",
        "status": "到達",
        "arrive_id": "1234567890123456",
        "arrive_date": "2024-01-15 09:30:00",
        "corporation_name": "株式会社サンプル",
        "applicant_name": "山田 太郎",
        "proc_name": "雇用保険被保険者資格喪失届"
      }
    ]
  }
}
```

## トークンレスポンス例

```json
{
  "access_token": "...",
  "expires_in": 3600,
  "refresh_expires_in": 15552000,
  "refresh_token": "...",
  "token_type": "Bearer",
  "id_token": "...",
  "scope": "openid offline_access"
}
```
