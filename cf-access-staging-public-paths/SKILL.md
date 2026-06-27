---
name: cf-access-staging-public-paths
description: ippoan の *-staging.ippoan.org ドメイン上で「公開ページ (LINE / LINE WORKS webview の viewer 等) が読み込み中で止まる / recipient だけ見れない / 管理者の自分のブラウザでは見れるのに他人は 401・302」の root cause 特定 + 修正手順。原因は account 全体の Cloud Run/Worker を覆う CF Access app **"staging-wildcard (allow me)" = `*-staging.ippoan.org`** が、明示 bypass した path 以外を全部 gate していること。viewer ページ本体を bypass しても **`/_nuxt/*` (JS/CSS) や ページが叩く API path、backend が server→server で POST する internal path** が gate されたままだと webview は hydrate できず無音で停止する。さらに **rust(reqwest) → Worker の internal POST が 302→cloudflareaccess login→200 を「成功」と誤認して silent fail する罠** (register-view が KV を書けてないのにエラーも warn も出ない) も収録。トリガー:「viewer 読み込み中で止まる」「LINE WORKS webview 表示されない」「recipient だけ見れない」「自分は見れるのに他人が 401」「staging だけ動かない」「Cloudflare Access に deny されてる」「register-view が飛ばない」「KV に書かれない」「302 cloudflareaccess login」「_nuxt 302」「staging-wildcard allow me」「公開ページ bypass」「webview stuck loading」等。
---

# CF Access が *-staging の公開 path を gate する罠

ippoan の Cloudflare account には **`*-staging.ippoan.org` を覆う CF Access app
「staging-wildcard (allow me)」**(policy = `me` だけ allow) がある。これは staging を
本人以外に晒さないための包括 gate で、**明示的に bypass destination を持つ Access app
で上書きした path 以外は全部ログイン要求 (302 → `*.cloudflareaccess.com/cdn-cgi/access/login`)**
になる。

→ staging ドメイン上で「不特定の第三者 (LINE / LINE WORKS webview の recipient 等) に
公開したいページ」を作ると、**作った本人のブラウザは Access cookie を持っているので普通に
見えてしまい**、recipient だけが見れない / 無音で止まる、という非対称バグになる。

## 症状と一次診断 (60 秒)

| 観察 | 示唆 |
|---|---|
| **自分のブラウザでは表示される / recipient (webview) は「読み込み中」で止まる** | Access cookie の非対称。下を no-cookie で確認 |
| 公開ページ URL を **cookie 無しの curl** で叩くと `302` + `location: https://*.cloudflareaccess.com/.../login` | その path が Access で gate されている |
| ページ HTML (`/v/...`) は 200 だが、参照する `/_nuxt/*.js` `/_nuxt/*.css` が `302` | SPA の JS が取れず hydrate されない → 無音で停止 |
| backend (rust 等) → Worker の internal POST が「成功」なのに相手に届いていない | **302→login(200) を success 誤認** (下記の罠) |

```sh
# recipient / webview と同じ「cookie 無し」状態で各リソースを叩く (302=gate)
B=https://<svc>-staging.ippoan.org
for u in "/v/<token>" "/_nuxt/<hash>.js" "/_nuxt/<hash>.css" "/api/<...>/public-endpoint"; do
  printf '%-50s ' "$u"; curl -s -o /dev/null -w '%{http_code}\n' "$B$u"
done
# 302 が出た path が「公開のはずなのに Access に食われている」path
```

「自分は見れる」は **証拠にならない** (Access cookie を持っているだけ)。必ず no-cookie で確認する。

## Nuxt SPA の公開ページに必要な bypass path

viewer 系の公開 Nuxt ページを webview/recipient に出すには、**ページ単体では足りない**。
最低限これらを全部 bypass する:

| path | 役割 | 無いとどうなる |
|---|---|---|
| `/<page-prefix>` (例 `/v`) | ページ HTML (SSR) | ページ自体が 302 |
| **`/_nuxt`** | client JS / CSS バンドル | **HTML は出るが hydrate されず「読み込み中」で停止** (最も気付きにくい) |
| ページが fetch する公開 API (例 `/api/notify/v`) | メタ / ファイル配信 | データ取得が 302 で死ぬ |
| backend が server→server で POST する internal path (例 `/api/notify/register-view`) | KV 登録等 | **下記 silent fail** |

- フォント (`.woff2` 等) は **CSS が参照していれば**追加。参照ゼロなら不要
  (`curl -s /_nuxt/entry.<hash>.css | grep -cE 'woff|ttf'` で確認)。表示崩れはするが
  hydrate はブロックしない (fallback font で出る) ので「読み込み中」の主因ではない。
- `/<page-prefix>/<token>/_payload.json` は `/<page-prefix>` prefix に含まれるので
  個別追加不要 (payload 未使用なら 404 でも無害)。
- internal POST endpoint を public bypass しても、その endpoint 自身が
  `INTERNAL_SHARED_SECRET` 等で自前認証しているなら安全 (Access は二重の壁でしかない)。

## server→server POST が 302 を success 誤認する罠 (重要)

backend が staging の Worker へ internal POST するとき (例: rust の `ViewerRegisterClient`
→ `POST /api/notify/register-view`)、その path が Access gate されていると:

```
rust(reqwest) --POST--> CF Access (cookie 無し) --302--> cloudflareaccess login
   reqwest は redirect を既定で追う → login ページが 200 を返す
   → resp.status().is_success() == true → Ok(()) → warn も出ない
   → でも Worker は POST を受信していない → KV/相手側に何も書かれない
```

結果、**送信側ログにも受信側 (Worker observability) ログにも痕跡が出ない**まま下流が空になる。
「register が飛ばない / KV に書かれないのにエラーが無い」の正体はこれ。

**ハードニング (推奨)**: internal POST 用の HTTP client は **redirect を追わない**
(`reqwest::redirect::Policy::none()`) にする。302 が非 2xx として `Err` になり即 warn が出て
一発で気付ける。Access bypass を入れた後もこの hardening は入れておく (別 PoP・別 env で
再発防止)。

## 修正手順 (cf-access-mcp)

`mcp__cf-access-mcp__*` で account の Access app を操作する (値は出さない / read は scope 不要)。

1. `list_access_apps` → 対象ドメインを覆う app を探す
   - 包括 gate = `*-staging.ippoan.org` の **"staging-wildcard (allow me)"** (policy: me/allow)
   - 既存の公開 bypass app があれば再利用 (例: `notify-staging /v public (LINE webview)`、
     policy = `bypassAll` (everyone / **decision: bypass**)、reusable)
2. `get_access_app <uid>` で **完全な現設定を取得** (update は full replace = PUT なので)
3. `update_access_app` で `self_hosted_domains` + `destinations` に公開 path を追記
   (policy は reusable を id 参照で維持):

```jsonc
// patch (既存 + 追加分を全部列挙する。full replace なので欠けると消える)
{
  "name": "<svc>-staging public (webview)", "type": "self_hosted",
  "domain": "<svc>-staging.ippoan.org/v",
  "self_hosted_domains": [
    "<svc>-staging.ippoan.org/v",
    "<svc>-staging.ippoan.org/_nuxt",
    "<svc>-staging.ippoan.org/api/<page-public-api>",
    "<svc>-staging.ippoan.org/api/<internal-post-endpoint>"
  ],
  "destinations": [
    {"type":"public","uri":"<svc>-staging.ippoan.org/v"},
    {"type":"public","uri":"<svc>-staging.ippoan.org/_nuxt"},
    {"type":"public","uri":"<svc>-staging.ippoan.org/api/<page-public-api>"},
    {"type":"public","uri":"<svc>-staging.ippoan.org/api/<internal-post-endpoint>"}
  ],
  "session_duration": "24h", "app_launcher_visible": true,
  "http_only_cookie_attribute": true,
  "policies": [{"id":"<bypass-policy-uid>","precedence":1}]
}
```

4. 数秒待って **no-cookie curl で 302→200/401 に変わったか**を全 path 確認 (上の probe 再実行)。
   - 公開 API が `401`(=自前認証に到達) や `200` になれば Access 突破成功 (302 でなければ OK)。

`destinations` の path は **prefix match** (`/api/notify/v` が `/api/notify/v/{token}` と
`.../file` を両方カバー)。広げすぎると別の保護対象まで開くので、**公開が必要な prefix だけ**
足す (`/api/notify` 丸ごとではなく `/api/notify/v` のように絞る)。

## prod パリティ

prod ドメイン (`<svc>.ippoan.org`) が Access 配下なら **同じ bypass が必須**。`*-staging`
wildcard は prod を覆わないが、prod 用の別 Access app があるか確認し、無ければ公開 path は
そのまま通る / あれば同じ destination を足す。staging で直ったから prod も大丈夫、とは限らない。

## 補助デバッグツール (今回使った経路)

- **Worker (受信側) のログ**: `mcp__cf_logging__query_worker_observability`
  (service= `<svc>-staging`)。Access が 302 で食った POST は **Worker に到達しないので
  ここに出ない** = 「届いてない」の判定に使える。
- **Cloud Run (送信側 rust) のログ**: `mcp__cloudlogging__list_log_entries`
  (`resource.labels.service_name="<svc>-staging"`, `logName=".../stdout"`)。tracing は
  **`jsonPayload.fields.message`** に入る (textPayload フィルタでは引っかからない)。
- **env と GCP Secret Manager の値一致確認**: rust に `/api/health/secret-fingerprint?name=<ENV>`
  があれば runtime env と SM latest を runtime SA で突合し `{"match":bool}` を返す (値は漏れない)。
  「secret がズレてる」を value-safe に否定/肯定できる。**route が `/api` 配下 nest なら実パスは
  `/api/health/...`** (`/health` 直は 404 になり得る)。
- **staging DB の揮発・非アフィニティ**: staging の Cloud Run は postgres sidecar +
  `emptyDir` + minScale 0 = **インスタンス毎に別 DB / idle で消える**。直 curl と UI が別
  インスタンスに当たってデータが見えない事がある。E2E は **upload→distribute を 1 リクエスト束
  (同一セッション) で連続実行**して同一インスタンスに乗せる。

## この罠の本質

- staging を `*-staging` wildcard で一括 Access 保護するのは正しい。が、**その上に「不特定多数に
  公開する path」を載せた瞬間**、bypass の網羅 (ページ + `/_nuxt` + 公開 API + internal POST 先)
  を忘れると無音で詰まる。
- 「自分のブラウザで見れる」は Access cookie 由来の **false positive**。検証は必ず no-cookie。
- server→server の internal 呼び出しも staging ドメイン宛なら Access を通る。reqwest 等の
  **redirect 追従が 302 を 200 に化けさせて silent fail** させるので `redirect(none)` で守る。

---

_実例: ippoan/rust-alc-api#434 の notify 公開 viewer (nuxt-notify-staging)。
`/v` だけ bypass 済だったが `/api/notify/v` `/api/notify/register-view` `/_nuxt` が
`*-staging` wildcard に gate され、(1) recipient の webview が JS/API を取れず「読み込み中」、
(2) rust の register-view POST が 302→login(200) で silent fail → KV 未登録、の二重で
viewer が出なかった。4 path を bypass app に追加して解消。_
