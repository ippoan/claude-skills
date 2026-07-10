---
name: cdp-pair
description: >
  CCoW (Claude Code on the Web) の隔離コンテナから手元 Chrome を cdp-relay 経由で
  操作するための pairing スキル。3 経路: (A) chrome-devtools-mcp passthrough —
  browser_cdp_endpoint で発行した pair_string を MV3 拡張 popup に貼って手元 Chrome の
  browser-level 生 CDP を cdp-relay 経由で中継し、CCoW の chrome-devtools-mcp を
  --wsEndpoint で合流させて **chrome-devtools-mcp の全ツール** (network/perf/DOM/console)
  を効かせる。(B 軽量) curated — browser_pair の pair_string で /ext に合流し
  browser_navigate / browser_screenshot / browser_eval を直接使う (追加セットアップ不要)。
  (C 高速) MCP passthrough — browser_mcp_endpoint + 手元 node bridge --mcp で
  chrome-devtools-mcp を手元 spawn し、MCP JSON-RPC だけを relay (1 ツール = 海越え
  1 往復 ~0.3s、A の約 4 倍速。cdp-relay#81/#82)。
  トリガー: 「手元の Chrome を操作」「手元ブラウザ」「cdp-relay」「chrome-devtools-mcp」
  「browser_cdp_endpoint」「wsEndpoint」「CDP passthrough」「browser_pair」「pairing」
  「ペアリング」「pair_code」「拡張を接続」「CCoW からブラウザを見たい」
  「cdp-relay.ippoan.org」「extension_not_connected」「remote-allow-origins」
  「cdp_bridge_not_connected」「mcp_bridge_not_connected」「Chrome 136」「user-data-dir」
  「ゲストモードで開く」「CDP 取得に失敗」「Failed to fetch 9222」「passthrough 遅い」
  「レイテンシ」「browser_mcp_endpoint」「mcppipe」「MCP passthrough」「bridge --mcp」等。
  cdp-browser (Tailscale 直 CDP) / cdp-agent (MSI quick tunnel) とは別経路 — こちらは
  UDP 封鎖 + 手元 NAT 越えが要る CCoW 向けの拡張 → WSS/443 合流方式。
  通常の UI 動作確認 (画面遷移・表示・クリック・コンソールログ) だけなら公式
  Claude in Chrome 拡張 (Desktop/Cowork 経由) の方が pairing 不要で速い — reflex で
  cdp-pair に入る前に claude-in-chrome skill の使い分け早見表を参照。
---

# cdp-pair — 手元 Chrome を cdp-relay 経由でペアリングして操作

CCoW コンテナは手元 Chrome へ直接 CDP 接続できない (Tailscale 網外 + UDP 封鎖)。
唯一通る TCP/443 の WSS で、手元拡張と CCoW を Cloudflare DO に合流させて操作する。
このスキルはその合流 (= pairing) を Claude が主導するための手順を定める。

> **先に経路選定**: 通常の UI 動作確認 (画面遷移・表示・クリック・コンソールログ・
> CF Access 配下の目視) だけなら、公式 **Claude in Chrome** 拡張を Desktop / Cowork から
> 使う方が pairing 不要で速い。cdp-pair が必須なのは「CCoW セッション自身が操作する」
> 「httpOnly Cookie ログイン委譲 (`browser_cookies`)」「ヘッダ/ボディ込み network 解析・
> 生 CDP (経路 A)」の場面。使い分け早見表は **claude-in-chrome skill** を参照
> (実機検証: ohishi-exp/nuxt-dtako-admin#196)。

MCP server: `https://cdp-relay.ippoan.org/mcp` (ippoan 標準 MCP-JWT 認証。`session-start-write-mcp-user-scope.sh`
hook が `~/.claude.json` に自動 attach するので tool 呼び出し自体に手動設定は要らない)。

ツール:
- `mcp__cdp-relay__browser_cdp_endpoint(session?, ttl_seconds?)` → `{ session, pair_code,
  relay_url, ws_endpoint, chrome_devtools_mcp_command, pair_string }` (**経路 A** 用、mode=cdp)
- `mcp__cdp-relay__browser_pair(session?, ttl_seconds?)` → `{ session, pair_code,
  relay_url, pair_string }` (**経路 B** 用、curated)
- `mcp__cdp-relay__browser_navigate(session, url)` / `browser_screenshot(session)` /
  `browser_eval(session, expression)` / `browser_stash` / `browser_cookies` (経路 B、curated)

## どの経路を使うか

| | **A. CDP passthrough** | **B. curated (軽量)** | **C. MCP passthrough (高速)** |
|---|---|---|---|
| 発行 tool | `browser_cdp_endpoint` | `browser_pair` | `browser_mcp_endpoint` |
| 手元に必要 | debug port Chrome + 拡張 (or node bridge) | 拡張のみ (通常起動 Chrome) | debug port Chrome + **node bridge `--mcp` 必須** |
| CCoW 側 | `chrome-devtools-mcp --wsEndpoint` | cdp-relay の browser_* を直接呼ぶ | stdio シム (`claude mcp add`) or WS 直結 |
| 使える範囲 | chrome-devtools-mcp 全ツール | navigate / screenshot / eval / cookies | chrome-devtools-mcp 全ツール |
| 1 ツールの海越え往復 | 4〜5 (warm ~1.1s) | 1 | **1 (~0.3s、A の約 4 倍)** |
| 操作対象 | 専用 profile の全タブ | **普段使い Chrome のタブ** | 専用 profile の全タブ |

「今すぐ画面を見たい / ログイン済み cookie 状態が要る」→ **B**。
「chrome-devtools-mcp の全ツール + 操作を連打する」→ **C**。
「生 CDP そのものが要る / 手元に node を置きたくない (拡張 SW が bridge になる)」→ **A**。

## なぜ pairing code を使うか (RELAY_TOKEN を会話に出さない)

`RELAY_TOKEN` は無期限の共有秘密で、漏れると任意 JS eval = ブラウザ乗っ取りに直結する。
代わりに両 tool が **session 単位・短命 (既定 15 分) の 256-bit pairing code** を発行する。
pair_code は TTL + session スコープで自然失効するので会話に出してよい。**pair_code /
pair_string は会話で手元に渡してよいが、`RELAY_TOKEN` の値は会話・log・tool param に
絶対出さない。**

---

## 経路 A: chrome-devtools-mcp passthrough

手元 Chrome の browser-level 生 CDP を cdp-relay が透過中継し、CCoW の chrome-devtools-mcp
を `--wsEndpoint` で合流させる。拡張の Service Worker が bridge になるので手元に別プロセス
(node 等) は不要。

### A-1. エンドポイント一式を発行する

```
mcp__cdp-relay__browser_cdp_endpoint(session?, ttl_seconds?)
# → { session, pair_code, ws_endpoint,
#     chrome_devtools_mcp_command: 'npx chrome-devtools-mcp@latest --wsEndpoint "wss://…"',
#     pair_string: 'cdp1.…(mode=cdp)…' }
```

debug 設定に手間取りそうなら `ttl_seconds` を伸ばす (最大 86400 = 24h)。

### A-2. pair_string を popup に貼ってもらう

`pair_string` を渡し、拡張 popup の **「接続文字列（1コピペ）」欄**に貼るよう案内する。
mode=cdp が入っているので **「chrome-devtools-mcp (CDP passthrough)」チェックが自動 ON**
になり接続まで走る。

### A-3. 手元 Chrome を debug port 付きで起動してもらう

popup で CDP passthrough を ON にすると **「Chrome 起動コマンドをコピー」ボタン**が出る。
その完全コマンド (実行ファイル + フラグ) をショートカットのリンク先に貼って起動する:

```
"C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222 --remote-allow-origins=chrome-extension://<この拡張 id> --user-data-dir="%LOCALAPPDATA%\cdp-relay-chrome"
```

- **`--remote-allow-origins` は拡張 id スコープ** (`chrome-extension://<id>`)。**`*` は使わない**
  — 全 origin 許可 = 任意の Web ページから localhost の CDP を乗っ取られる (デバッグポート
  乗っ取り)。popup が出す値は既にこの拡張 id 限定になっている。
- これが無い / `*` だと、拡張 SW の WS (Origin: chrome-extension://…) を :9222 が拒否する。
- **`--user-data-dir` (非デフォルト dir) は Chrome 136+ で必須**。デフォルト profile に対する
  `--remote-debugging-port` は無視され、ポート自体が開かない
  (https://developer.chrome.com/blog/remote-debugging-port 、cookie 窃取対策)。
  症状は popup の `Chrome :9222 の CDP 取得に失敗: Failed to fetch`。
- **起動した Chrome がゲストモードで開いたら `--user-data-dir` が効いていない**サイン
  (パス不正時のフォールバック)。典型は **PowerShell に cmd 構文を貼った**ケース —
  PowerShell では `%LOCALAPPDATA%` が展開されず `^` も行継続でない。1 行のリテラルパス
  (`--user-data-dir=C:\chrome-cdp-profile` 等) にし、PowerShell では先頭に `&` を付ける。
  成否は起動した Chrome で `http://localhost:9222/json/version` を開いて JSON が返るかで確認。
- **操作対象はこの専用 profile 側の Chrome の全タブ** (普段使い profile は Chrome 136 制約で
  対象にできない — ログイン済み cookie 状態が要る確認は経路 B (chrome.debugger、通常起動の
  Chrome に効く) を使う。これが curated 経路を deprecate しない理由)。

status が **`connected: CDP passthrough (Chrome :9222)`** になれば手元側は準備完了
(popup debug ログに `cdp local (Chrome) open` → `cdp remote (cdp-relay) open`)。

### A-4. CCoW で chrome-devtools-mcp を起動する

`chrome_devtools_mcp_command` (`npx chrome-devtools-mcp@latest --wsEndpoint "wss://…"`) を、
**使う側の Claude の MCP server として登録**する (CCoW の `~/.claude.json` mcpServers →
**次 session で有効**)。登録すれば次 session で chrome-devtools-mcp の全ツールが手元
ブラウザに効く。

> **今すぐ疎通だけ確認したい**場合は、ws_endpoint に生 CDP を 1 往復投げる:
> ```sh
> node -e 'const w=new WebSocket("<ws_endpoint>");w.onopen=()=>w.send(JSON.stringify({id:1,method:"Browser.getVersion"}));w.onmessage=e=>{console.log(e.data);w.close()}'
> ```
> 手元 Chrome の version が返れば CCoW → cdp-relay → 拡張 bridge → 手元 Chrome が通っている。
> (自分の WS を閉じると拡張 bridge も一旦切れるが keepalive で再接続する)

### 経路 A の gotcha

- **`remote error` / `remote closed (1006)` が出たら まず pair_code 失効を疑う** →
  `browser_cdp_endpoint` を再発行して pair_string を貼り直す (手元 Chrome 側 =
  `cdp local (Chrome) open` は出るのに remote だけ失敗、が典型)。
- **接続順**: 拡張 (CDP passthrough) を先に connected にしてから chrome-devtools-mcp を
  起動する。bridge 未接続だと client 側は `cdp_bridge_not_connected` (503) で即失敗する。
- **client の WS エラーは中身が見えない** — Node native WS / undici は非 101 応答を
  「Received network error or non-101 status code」としか言わない。切り分けは relay に
  生 upgrade を投げて応答 body を見る: `503 {"error":"cdp_bridge_not_connected"}` なら
  経路・token は正常で手元 bridge 未接続なだけ。
- **`--remote-debugging-port` 起動忘れ / Chrome 136 の user-data-dir 無視** (A-3 参照) が
  最頻の詰まり。popup debug ログに `Chrome :9222 の CDP 取得に失敗` が出たら起動フラグと
  `localhost:9222/json/version` を確認。
- **CCoW からは直結 `wss://` がそのまま通る** (TCP/443 直結可、TLS は Anthropic Egress
  Gateway が MITM 終端するが `NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt` が標準設定
  なので Node / puppeteer は信頼する)。proxy シム・ProxyAgent は不要。
- Cloudflare の WS メッセージ上限は 32 MiB (CDP 用に引き上げ済み)。通常操作は収まる。

### 経路 A の実測値 (2026-07-10 疎通確認、Refs ippoan/cdp-relay#80)

- **疎通 3 点 + マルチタブ全通**: `list_pages` / `navigate_page` / `take_screenshot` /
  `new_page` / `select_page` / `evaluate_script` / `close_page` (chrome-devtools-mcp@1.5.0
  29 tools × Chrome 150/Windows)。`select_page` / `close_page` のパラメータは **`pageId`**
  (`list_pages` の番号を渡す)。
- **レイテンシ**: CDP 1 コマンド往復 = 中央値 **236ms** (日米間 RTT が支配的、物理下限)。
  1 ツール呼び出しは内部で 4〜5 コマンド直列 → **warm ~1.1s/call** (screenshot 0.6s)。
  初回は npx 起動 + WS 確立で ~8s (`claude mcp add` で常駐登録すれば償却)。
- **高速化は往復回数の削減のみ有効** — chrome-devtools-mcp を手元で動かし MCP を relay する
  「MCP passthrough モード」(1 call = 1 往復 ≈ 0.3s、約 4 倍) を ippoan/cdp-relay#81 で計画。
  ただしエージェント作業の体感はモデル推論時間 (5〜30s/turn) が支配するので過大評価しない。
  ブラウザ操作が主役の作業はエージェント自体を手元で動かす cc-webreview-ext の領分。
- chrome-devtools-mcp の flag は **`--wsEndpoint` / `--browserUrl`** (kebab-case ではない)。
  テレメトリは `CI=1` でも無効化できる。「タブ大量時の全タブ強制ロード」は Chrome 149 まで
  の挙動で 150 では非該当。

---

## 経路 C: MCP passthrough (高速版、cdp-relay#81/#82)

chrome-devtools-mcp を **手元で** spawn し、MCP JSON-RPC (1 ツール = 海越え 1 往復) だけを
relay する。経路 A と同じ全ツールが約 4 倍速く効く。**手元に node 必須** (拡張 SW は
プロセスを spawn できないため拡張だけでは完結しない — 導線改善は cdp-relay#83)。

### C-1. エンドポイント一式を発行する

```
mcp__cdp-relay__browser_mcp_endpoint(session?, ttl_seconds?)
# → { session, pair_code, ws_endpoint (wss://…/mcppipe/{s}?token=…),
#     bridge_command: 'node bridge/cdp-bridge.mjs --mcp --session … --token …',
#     claude_mcp_add_command }
```

session を跨いで tool が未 provision の場合でも、`browser_cdp_endpoint` で mint した
pair_code は全脚共通なので `/mcppipe/{session}?token=…` を手組みしてよい。

### C-2. 手元で bridge を起動してもらう

Chrome は経路 A と同じ debug port 起動 (Chrome 136+ は非デフォルト `--user-data-dir` 必須)。
**repo を clone していない手元マシン**では raw ファイル 1 個で bootstrap できる:

```
mkdir %USERPROFILE%\cdp-bridge 2>nul & cd /d %USERPROFILE%\cdp-bridge
curl.exe -O https://raw.githubusercontent.com/ippoan/cdp-relay/main/bridge/cdp-bridge.mjs
node cdp-bridge.mjs --mcp --session <session> --token <pair_code>
```

初回は npx が chrome-devtools-mcp を DL するので数十秒かかる。
`mcp remote (cdp-relay) open` が出たら手元側は準備完了。

### C-3. CCoW から繋ぐ

- 常用: `claude_mcp_add_command` (`claude mcp add chrome-local -- node bridge/mcp-stdio-shim.mjs
  --url "wss://…"`) を実行 → **次 session から** chrome-devtools-mcp の全ツールが生える
- 単発検証: `/mcppipe` に WS 直結して JSON-RPC (`initialize` → `tools/call`) を 1 行 =
  1 フレームで喋れば シム無しでも叩ける (CCoW は直結 wss 可、経路 A gotcha 参照)

### 経路 C の gotcha

- client (シム) 切断ごとに bridge は chrome-devtools-mcp child を作り直す (MCP の
  initialize は接続ごとに 1 回きりのため)。再接続で child 再 spawn の数秒が掛かる。
- bridge 未接続で client を繋ぐと 503 `{"error":"mcp_bridge_not_connected"}` (fail-fast)。
- スクリーンショット等の大きな応答は MCP body (base64) で返る — 生値を context に
  載せたくない場合は経路 B の shot_url 方式の方が向く。

---

## 経路 B: curated (browser_pair + 直接ツール)

追加セットアップ無しで、この session からそのまま手元ブラウザを操作する。

### B-1. ペアリングコードを発行する

```
mcp__cdp-relay__browser_pair(session?, ttl_seconds?)
# → { session, pair_code, relay_url, pair_string }  (mode 無し = curated)
```

### B-2. pair_string を popup に貼ってもらう

`pair_string` を「接続文字列（1コピペ）」欄に貼ると 3 欄が自動入力され、**CDP passthrough
チェックは OFF のまま** (mode 無しのため) /ext に合流する。**対象タブを選んで**「接続」を押し、
status が `connected: session=… tab=…` になったら教えてもらう。

> 個別に貼る場合の対応: Relay URL=`relay_url` / Session=`session` / Token=`pair_code`。
> 拡張未ロードなら先に `chrome://extensions` → デベロッパーモード → 「パッケージ化されて
> いない拡張機能を読み込む」で cdp-relay の `extension/` を選択。

### B-3. 疎通を確認して操作する

いきなり本題に入らず、まず `browser_screenshot(session)` で疎通確認する。

- `extension_not_connected` (503) → ① popup の Session 不一致 ② pair_code 貼り間違え/失効
  ③ 「接続」未押下 を順に確認。失効なら B-1 から再発行 (旧 code は即失効)。
- `{ shot_url }` → 合流 OK。

```
mcp__cdp-relay__browser_navigate(session, "https://example.com")   # http(s) のみ
mcp__cdp-relay__browser_screenshot(session)                       # → { shot_url }
```

```sh
curl -sS -o /tmp/shot.png "<shot_url>"   # 短命 (既定 5 分)・無認証 (予測不能 id)
```

その後 `Read /tmp/shot.png` で確認。撮ったら都度 Read する習慣にすると「画面を見て判断 →
次の操作」のループが回る。

---

## 共通で覚えておくこと

- **session 名は全 tool 呼び出しと popup で一致させる** (`session = idFromName(session)`
  で DO が決まる)。不一致だと `extension_not_connected` / `cdp_bridge_not_connected`。
- **pair_code は session 単位で 1 つ。** `browser_cdp_endpoint` / `browser_pair` を
  再発行すると同 session の旧 code は即失効する (経路 A↔B を切り替える時も貼り直し)。
- **pair_code / pair_string は短命。** 繋がらなくなったら**まず失効を疑って再発行**。
  長く使うなら発行時に `ttl_seconds` を伸ばす。
- **拡張 popup の Token と MCP-JWT は別物。** popup の Token は `/ext` `/cdpbridge` WS 用の
  pair_code。`/mcp` の MCP-JWT は hook が自動 attach するので混同しない。
- **拡張の版**: agent 管理版は `0.0.N` (dev-N 追従、更新ボタンで自動更新)、手動 git clone 版は
  `0.1.x` (別系統、更新は git pull)。詳細は cdp-relay の README / `docs/plan-chrome-devtools-mcp.md`。
- **navigate は http(s) のみ** (`chrome://` / `file://` は弾かれる、経路 B)。
