---
title: 公開 Worker の internal-only 機能は named WorkerEntrypoint RPC で binding-only にする
category: ops
status: recommended
recommended: named WorkerEntrypoint (RPC) — 公開 fetch に出さず service binding 専用にする
decision: 2026-06-27-auth-migration-oidc-custom-audience
---

公開ドメインを持つ Worker(例: auth-worker の `/alc-proxy`)に internal-only な機能を default `fetch`
ハンドラで生やすと、その path は公開 route からも叩ける(= shared secret 漏洩時に直叩きされる)。
**named `WorkerEntrypoint` クラス(non-default export)のメソッド**にすると、公開 route は default fetch
にしか向かないため service binding 専用になり公開面が消える(`X-...-Secret` gate を原理上不要にできる)。

- 性能: service binding の RPC は **同一サーバの同一スレッドで実行・ネットワーク hop 無し =「zero added
  latency」「almost as fast as a function call」**(CF 公式)。今の binding `.fetch()` も同条件なので RPC 化で
  レイテンシは増えない(HTTP serialize が消える分むしろ微減)。速度ボトルネックにはならない。
- consumer 側は `.fetch('/path')` を `env.<BINDING>.<method>(req)` に変える(RPC は JS オブジェクト直渡し)。
- 軽量代替(rearchitecture 不要): **`request.cf` の有無で判定**。外部 request は edge が `request.cf` を付ける
  が service binding の `fetch()` には無い → `if (request.cf) return 403` の 1 行で実質 binding-only。攻撃者は
  edge 経由なので `cf` を消せず偽造もできない。RPC ほど堅くないので belt-and-suspenders 向き。
- もう 1 つの代替: route/custom-domain を一切持たない**専用 Worker**(公開 URL なし)に切り出す。機微 binding
  (`JWT_SECRET` / SA key 等)を複製するコストあり。

判定根拠(rust-alc-api #434): `/alc-proxy` は当初 public route + `X-Alc-Proxy-Secret` gate だったが、secret
漏洩耐性のため RPC 化(binding-only)を採用。RPC のレイテンシ懸念は「zero overhead」で否定された。

参考: CF docs "Service bindings (RPC / WorkerEntrypoint)" / blog "JavaScript-native RPC"。
