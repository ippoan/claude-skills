---
name: cdp-agent
description: >
  手元 Chrome に MSI で入れた cdp-agent (quick tunnel + MCP server + 拡張) 経由で、
  CCoW から手元ブラウザを操作するスキル。拡張 popup の「接続用プロンプトをコピー」で
  渡された MCP URL (https://<rnd>.trycloudflare.com/mcp) に curl で tools/call し、
  browser_navigate / browser_screenshot を実行する。screenshot は base64 PNG を
  /tmp に保存して Read tool で画面を確認する。cdp-pair (Worker+DO / WS / pairing code)
  や cdp-browser (Tailscale 直 CDP) とは別経路 — こちらは MSI agent + 拡張 long-poll の
  self-host 構成 (ippoan/cdp-relay#12)。
  トリガー: 「手元 Chrome 操作」「cdp-agent」「接続用プロンプト」「cdp-relay agent」
  「trycloudflare の MCP」「browser_screenshot で手元」「MSI で入れた agent」
  「手元ブラウザを見て」「19222」等。
---

# cdp-agent — MSI agent 経由で手元 Chrome を操作

## これは何か

ユーザーが手元 Windows に `cdp-agent` (MSI) を入れて起動し、拡張を接続した状態で、
CCoW から手元ブラウザを CDP 操作するためのスキル。経路:

```
CCoW (curl) → cf quick tunnel → cdp-agent /mcp → 拡張 (long-poll) → chrome.debugger → 手元 Chrome
```

他の cdp スキルとの違い:

| skill | 経路 |
|---|---|
| **cdp-agent** (本スキル) | 手元 MSI agent + quick tunnel + 拡張 long-poll (self-host) |
| cdp-pair | Cloudflare Worker+DO + WS + pairing code |
| cdp-browser | Tailscale 直 CDP (port 9223 / Playwright) |

## 前提 (ユーザー側)

1. 手元 Windows に MSI 導入: <https://github.com/ippoan/cdp-relay/releases> の
   `cdp-agent-*-x86_64.msi` (dev prerelease)。スタートメニュー > **cdp-relay agent** で起動
2. `chrome://extensions` で `C:\Program Files\cdp-relay-agent\extension` を読み込む
   (unpacked)。popup で対象タブを選び「接続」(Relay URL は `http://127.0.0.1:19222` 既定)
3. popup の **「接続用プロンプトをコピー」** を押して CCoW に貼る → MCP URL が渡される

## 使い方

MCP URL (例 `https://courage-recipients-glen-hosts.trycloudflare.com/mcp`) を受けたら
`scripts/cdp-call.sh` で操作する:

```sh
# 手元画面を撮って /tmp/cdp-shot.png に保存 → Read tool で見る
bash ~/.claude/skills/cdp-agent/scripts/cdp-call.sh <MCP_URL> screenshot
# その後 Read /tmp/cdp-shot.png

# 手元タブを遷移
bash ~/.claude/skills/cdp-agent/scripts/cdp-call.sh <MCP_URL> navigate https://example.com/
```

screenshot を撮ったら必ず **Read tool で /tmp/cdp-shot.png を開いて画面を確認**する
(MCP の image content をそのまま base64 で会話に載せない = token 浪費回避)。

## 注意 / gotcha

- **quick tunnel URL は agent 再起動で変わる (揮発)**。`cdp_timeout` や到達失敗が出たら、
  ユーザーに拡張の「接続用プロンプトをコピー」で**新しい MCP URL を取り直して**もらう。
  rendezvous (cdp-proxy を固定 stdio で MCP 登録) を使えば URL 追従は proxy が吸収する
  ので、その構成なら curl でなく `browser_navigate` を直接呼べる。
- **`extension not connected` / `cdp_timeout (extension not connected?)`** が返ったら、
  拡張 popup で対象タブを選んで「接続」するようユーザーに促す (agent は動いているが
  拡張が `/ext/poll` していない状態)。
- CCoW → trycloudflare は **TCP/443 で到達**し、TLS は system CA で通る
  (`ccow-network-egress` 参照)。curl はそのまま通る。
- `/ext/*` は localhost 専用 port (tunnel しない) なので CCoW からは触れない。CCoW が
  叩くのは `/mcp` (tunnel 公開) だけ。

## 関連

- 実装: [ippoan/cdp-relay#12](https://github.com/ippoan/cdp-relay/issues/12)
- ネットワーク前提: `ccow-network-egress` skill
- 別経路: `cdp-pair` (Worker+DO) / `cdp-browser` (Tailscale 直)
