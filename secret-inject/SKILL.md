---
name: secret-inject
description: secret を GCP(source-of-truth)/Cloudflare Secrets Store/GitHub Actions org secret に no-leak で投入・rotate するスキル。値を LLM context / tool-call JSON / log に一切載せず、shell var → curl body → worker → Secret Manager の経路だけを通す。CCoW container の OAT から mcp.write の binding_jwt を mint して security-inventory の /mcp/secret-upload に直送する。トリガー:「secret 投入」「secret 作成」「secret rotate」「ingest secret」「Secrets Store に入れる」「GitHub org secret 作成」「値を context に載せず」「no-leak secret」「create_secret したい」「secret-inject」等。create_secret MCP tool は value が tool param に載る (= context leak) ので、生成系の secret はこのスキルを使う。
---

# secret-inject — no-leak で secret を 3 system に投入

secret の**値を LLM context に一切通さず** GCP(SoT) / Cloudflare Secrets Store /
GitHub Actions org secret に投入・rotate する。

## なぜ MCP tool でなくこれを使うか

secrets-inventory の `create_secret` / `rotate_secret` MCP tool は `initial_value`
を **string parameter** で受けるので、値が tool-call JSON ＝ LLM context に載る。
secrets 基盤は「値を会話 / tool-call / log に載せない」が大原則なので、**Claude が
値を扱う生成系 secret は MCP tool で投入してはいけない**。

代わりに値を **shell の中だけ**で扱い、`--data-binary` で worker に直送する HTTP
route (`PUT /mcp/secret-upload/:name`) を使う。値は `shell var → curl body →
worker memory → Secret Manager` だけを通り、context にも response/log にも出ない。

## 経路 (claude-md install.sh の OAT bootstrap から再構成)

```
CCoW container の Anthropic OAT
  /home/claude/.claude/remote/.oauth_token
        │  POST {AUTH_ORIGIN}/mcp/pair/grant-via-oat
        │  Bearer <OAT>  body {"aud":"github-mcp-server-rs","scope":"mcp.read mcp.write"}
        ▼
  binding_jwt (mcp.write scope)
        │  PUT {UPLOAD_ORIGIN}/mcp/secret-upload/<NAME>?targets=gcp,cf,github&mode=create
        │  Bearer <binding_jwt>  --data-binary @<value>   (value は stdin 由来)
        ▼
  GCP Secret Manager (SoT) → mirror → CF Secrets Store + GitHub Actions org secret
```

- `aud=github-mcp-server-rs`: secrets worker の binding-jwt middleware は aud 非厳格
  (`expectedAud=null`) で github-mcp aud の JWT を introspect 経由で受理する。
- `targets` には **必ず `gcp` を含める** (SoT を外すと inventory drift 検出が壊れ 400)。
- prod auth-worker は時々 **503** を返す (transient)。script は指数 backoff で retry する。
- 503 が `{"error_description":"MCP_OAUTH_KV not bound"}` で**継続**する場合は prod
  auth-worker の KV binding 欠落 (インフラバグ)。その間は staging で mint に切替える:
  `SECRET_AUTH_ORIGIN=https://auth-staging.ippoan.org`。prod の security-inventory は
  staging-minted JWT も introspect 受理する (aud 非厳格)。**値の投入先 (gcp/cf/github)
  は target で決まる**ので、auth を staging にしても prod の secret store に入る。
- worker は **trailing whitespace を default で reject** する。script は末尾改行を除去
  済み (`openssl rand` の改行対策)。意図的に残すなら `SECRET_KEEP_TRAILING=1`。

## 使い方

値は **必ず stdin** から渡す (argv に置くと process list に残る)。

```bash
SKILL=~/.claude/skills/secret-inject/scripts/inject-secret.sh

# (a) ランダム生成して新規投入 (ingest secret など)
openssl rand -hex 32 | bash "$SKILL" SYMBOL_INDEX_INGEST_SECRET

# (b) 既存値ファイルから (使用後は必ず shred)
bash "$SKILL" MY_SECRET < /tmp/value && shred -u /tmp/value

# (c) 既存 secret を rotate
openssl rand -hex 32 | bash "$SKILL" MY_SECRET --rotate

# (d) target / 既存上書きを指定
openssl rand -hex 32 | bash "$SKILL" MY_SECRET --targets gcp,cf --allow-existing
```

オプション:

| flag | 意味 |
|---|---|
| `--rotate` | `mode=create` でなく `mode=rotate` (既存値を更新) |
| `--targets a,b,c` | 投入先 (default `gcp,cf,github`)。`gcp` は外せない |
| `--allow-existing` | `fail_if_exists=false` (既存衝突を許容 = 新 version) |

env override: `SECRET_AUTH_ORIGIN` (default `https://auth.ippoan.org`) /
`SECRET_UPLOAD_ORIGIN` (default `https://security-inventory.ippoan.org`) /
`SECRET_OAT_FILE`。

## 出力

HTTP code と response の **metadata のみ**。値は一切 echo しない。`200` で成功。

## 投入後: Cloudflare Worker から使う

CF Secrets Store に入った secret を Worker で読むには `wrangler.jsonc` に binding を足す:

```jsonc
"secrets_store_secrets": [
  { "binding": "MY_SECRET", "store_id": "<account secrets store id>", "secret_name": "MY_SECRET" }
]
```

GitHub Actions org secret は同名で参照できる (`${{ secrets.MY_SECRET }}`)。

## 関連

- secrets-inventory MCP の read 系 (`list_inventory` / `get_drift`) は値を扱わないので MCP tool で OK。
- `package-publish-debug` — GHCR/npm の PAT 系トラブル。
- cross-repo-symbol-index — ingest secret `SYMBOL_INDEX_INGEST_SECRET` の投入にこれを使う。
