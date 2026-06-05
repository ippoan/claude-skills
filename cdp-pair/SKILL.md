---
name: cdp-pair
description: >
  CCoW (Claude Code on the Web) の隔離コンテナから手元 Chrome を cdp-relay 経由で
  操作するための pairing フローを実行するスキル。browser_pair で短命 pairing code を
  発行し、その relay_url / session / pair_code を MV3 拡張 popup に貼ってもらって WS を
  合流させ、以降 browser_navigate / browser_screenshot で手元ブラウザを操作する。
  トリガー: 「手元の Chrome を操作」「手元ブラウザ」「cdp-relay」「browser_pair」
  「pairing」「ペアリング」「pair_code」「拡張を接続」「CCoW からブラウザを見たい」
  「cdp-relay.ippoan.org」「extension_not_connected」等。
  cdp-browser スキル (Tailscale 直 CDP + port 9223 + Playwright) とは別物 — そちらは
  直結が通る環境向け。CCoW のように UDP 封鎖 + 手元 NAT 越えが必要な環境ではこちらを使う。
---

# cdp-pair — 手元 Chrome を cdp-relay 経由でペアリングして操作

CCoW コンテナは手元 Chrome へ直接 CDP 接続できない (Tailscale 網外 + UDP 封鎖)。
唯一通る TCP/443 の WSS で、手元拡張と MCP tool を Cloudflare DO に合流させて操作する。
このスキルはその合流 (= pairing) を Claude が主導するための手順を定める。

MCP server: `https://cdp-relay.ippoan.org/mcp` (ippoan 標準 MCP-JWT 認証。`session-start-write-mcp-user-scope.sh`
hook が `~/.claude.json` に自動 attach するので tool 呼び出し自体に手動設定は要らない)。

ツール:
- `mcp__cdp-relay__browser_pair(session?, ttl_seconds?)` → `{ session, pair_code, expires_in_seconds, relay_url }`
- `mcp__cdp-relay__browser_navigate(session, url)` → `{ url }`
- `mcp__cdp-relay__browser_screenshot(session)` → `{ shot_url }`

## なぜ pairing code を使うか (RELAY_TOKEN を会話に出さない)

`RELAY_TOKEN` は無期限の共有秘密で、漏れると任意 JS eval = ブラウザ乗っ取りに直結する。
代わりに `browser_pair` が **session 単位・短命 (既定 15 分) の 256-bit pairing code** を
発行する。pairing code は TTL + session スコープで自然失効するので、会話に出しても
`RELAY_TOKEN` を出すのとは安全性が桁違い。**だから pair_code は会話で手元に渡してよいが、
`RELAY_TOKEN` の値は会話・log・tool param に絶対出さない。**

## 標準フロー

### 1. ペアリングコードを発行する

ユーザーが「手元の Chrome を操作して」と言ったら、まず `browser_pair` を呼ぶ。
session を指定したいなら渡す (省略すると `pair-xxxxxxxx` がランダム採番される)。
以降の navigate / screenshot で同じ session 名を使うので、戻り値の `session` を覚えておく。

```
mcp__cdp-relay__browser_pair()
# → { session: "pair-3f9a…", pair_code: "…(256bit hex)…",
#     expires_in_seconds: 900, relay_url: "https://cdp-relay.ippoan.org" }
```

ttl を延ばしたい時 (例: 設定に手間取りそう) は `ttl_seconds` を渡す (最大 86400)。

### 2. 3 値を提示して popup に貼ってもらう

戻り値の 3 値を、拡張 popup のどの欄に貼るか明示してユーザーに渡す。Markdown の表か
箇条書きで、**Relay URL / Session / Token の対応を取り違えないように**示すこと:

| popup の欄 | 貼る値 |
|---|---|
| **Relay URL** | `relay_url` (例 `https://cdp-relay.ippoan.org`) |
| **Session** | `session` |
| **Token** | `pair_code` ← pairing code をここに |

そして「対象タブを選んで『接続』を押し、status が `connected` になったら教えてください」と
案内する。

> 拡張がまだ手元 Chrome にロードされていない場合は、先に 1 度だけロードが要る:
> `chrome://extensions` → デベロッパーモード ON → 「パッケージ化されていない拡張機能を
> 読み込む」で cdp-relay の `extension/` ディレクトリを選択。詳細は cdp-relay の README
> 「拡張のロード」節。

### 3. 疎通を確認する

ユーザーが「接続した」と言ったら、**いきなり本題の操作に入らず**まず疎通を確認する。
`browser_screenshot` を 1 枚撮ってみるのが手軽:

```
mcp__cdp-relay__browser_screenshot(session)   # 同じ session 名を渡す
```

- `extension_not_connected` (503) が返る → 拡張がその session の DO にまだ合流していない。
  考えられる原因: ① popup の Session が手元と不一致 ② pair_code を貼り間違え / 期限切れ
  ③ 「接続」を押していない / status が connected でない。①②③ を順に確認してもらう。
  pair_code が期限切れ (発行から ttl 超過) なら **手順 1 からやり直して再発行**する
  (再発行すると旧 code は失効する点に注意)。
- `{ shot_url }` が返る → 合流できている。次へ。

### 4. 操作する

以降は navigate / screenshot を必要なだけ呼ぶ。screenshot の PNG 本体は token 浪費回避の
ため MCP に載らない。`shot_url` を curl で落として Read で見る:

```
mcp__cdp-relay__browser_navigate(session, "https://example.com")   # http(s) のみ
mcp__cdp-relay__browser_screenshot(session)
# → { shot_url: "https://cdp-relay.ippoan.org/shot/…/…" }
```

```sh
curl -sS -o /tmp/shot.png "<shot_url>"   # shot_url は短命 (既定 5 分)、無認証 (予測不能 id)
```

その後 `Read /tmp/shot.png` で画像を確認し、ユーザーに見せる。撮ったら都度 Read する習慣に
すると「画面を見て判断 → 次の操作」のループが回る。

## 覚えておくこと

- **session 名は全 tool 呼び出しと popup で一致させる。** 不一致だと別 DO に振り分けられ
  `extension_not_connected` になる (`session = idFromName(session)` で DO が決まるため)。
- **pair_code は session 単位で 1 つ。** `browser_pair` を再発行すると旧 code は即失効する。
  複数回呼ばない (呼んだら最後の code で貼り直してもらう)。
- **navigate は http(s) のみ。** `chrome://` や `file://` は弾かれる。
- **shot_url / pair_code は短命。** screenshot を撮ったらすぐ curl + Read、放置しない。
- **拡張 popup の Token と MCP-JWT は別物。** popup の Token は `/ext` WS 用の pair_code。
  `/mcp` の MCP-JWT は hook が自動 attach するので混同しない。
- まだ 1 度も `browser_pair` を呼んでいないのに `browser_navigate` を呼ぶと
  `extension_not_connected` になる。**操作の前提は「pairing 済み」。** 新しい会話で操作を
  頼まれたら、まず手順 1 から始める。
