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

## ⚠️ GitHub 投入先 org は **default = ippoan** (他 org は別経路)

`inject-secret.sh` の `--targets github` で投入される org は **proxy 既定 = ippoan** で
固定。スクリプトに `--gh-org` のような flag は無い (= ohishi-exp など別 org には届かない)。

dtako-scraper / daiun-salary など `ohishi-exp` org の repo から secret を引きたい場合、
**`inject-secret.sh` だけで投入すると ippoan に入って終わる**ので、ohishi-exp の
repo workflow からは `secrets.MY_SECRET` を引いても空になる (= ohishi-exp/dtako-scraper#9
で実際に踏んだ罠、2026-06-15)。

正しい手順 (2 段階、value は context に一切載らない):

```bash
# (1) 値を GCP に投入 (+ 任意で ippoan org にも mirror)。値は stdin のみ。
openssl rand -hex 32 | bash "$SKILL" KAGOYA_VPS_SSH_KEY --targets gcp

# (2) GCP の値を他 org に propagate (MCP tool 経由、value parameter なし)
#     mcp__secret-manger__sync_from_gcp:
#       { name: "KAGOYA_VPS_SSH_KEY",
#         gh_org: "ohishi-exp",
#         targets: ["gh"],
#         visibility: "all" }     # public repo から引きたい時必須
```

**前提**: `secrets-inventory-gcp` Cloud Run proxy で **App mode** が有効化されている
こと (`GH_APP_ID_SECRET_NAME` + `GH_APP_PRIVATE_KEY_SECRET_NAME` set、Refs
ippoan/secrets-inventory-gcp#51 / #55)。

- App mode 有効なら GitHub App `ippoan-ci-bot` が install されている全 org
  (ippoan + ohishi-exp + ...) に propagate 可能 (per-org PAT 不要)
- App mode 無効 / PAT mode のみの場合は proxy が `gh_org not allowed` で 400 を返す
- App permissions に "Organization permissions → Secrets: Read and write" が
  無いと 403。caller org で `auto-merge.yml` が動いていれば書込権限はあると推測できる
- 投入先 GCP secret の per-secret `secretAccessor` を proxy runtime SA
  (`secrets-inventory-viewer@cloudsql-sv.iam.gserviceaccount.com`) に grant
  しておかないと proxy が値を読めない (CI_APP_ID 等を新規追加する時の罠)

**判定フロー** (今後の secret 投入時にまず確認すること):

| 投入先 org | 手順 |
|---|---|
| ippoan のみ | `inject-secret.sh --targets gcp,github` だけで完結 |
| ohishi-exp など他 org | `inject-secret.sh --targets gcp` で GCP に置く → `sync_from_gcp(gh_org=...)` MCP tool で propagate |
| 複数 org | GCP 経由で hub-and-spoke、SoT は GCP 1 つ |

**public repo の visibility 罠**: GitHub org secret は新規作成時の default visibility
が `"private"` (private repos のみ参照可) のケースあり。public repo の workflow から
引くなら `sync_from_gcp(..., visibility="all")` を明示する。`inject-secret.sh` 経由
だと proxy 既定の `all` で作成されるので問題ないが、UI 経由で人手作成した secret は
要確認 (Settings → Secrets and variables → Actions → 該当 secret の
"Repository access")。

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
