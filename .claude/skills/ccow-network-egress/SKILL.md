---
name: ccow-network-egress
description: CCoW (Claude Code on the Web) コンテナの outbound ネットワーク制約の実測リファレンス + 60 秒 probe。UDP は全 block (STUN 往復が返らない)、TCP は 443 のみ到達かつ TLS は Anthropic egress gateway が MITM 終端する、という確定事実をまとめる。この制約から「WebRTC / P2P 直結 / TURN (Cloudflare Realtime TURN 含む) は CCoW から不成立」「transport 層暗号化 (TLS/DTLS) は egress 再終端で中継からコンテナを守れない」「中継に中身を見せないにはアプリ層 E2E のみ」が導かれる。CCoW セッションから P2P / WebRTC / 直結 / TURN / STUN / 任意 UDP の可否を判断する前、あるいは egress の TLS MITM・到達性で詰まった時に必ず参照すること。トリガー:「CCoW で P2P できる」「WebRTC CCoW」「直結したい」「UDP 通る」「STUN timeout」「TURN 使える」「Cloudflare Realtime TURN」「egress MITM」「Anthropic Egress Gateway CA」「TLS が割られる」「中継に中身を見せたくない」「コンテナから外に繋がらない」「ホールパンチ」等。
---

# ccow-network-egress

CCoW (Claude Code on the Web) コンテナの outbound 到達性は **HTTP/TLS 検査型 forward
proxy** で強く絞られている。WebRTC / P2P / 任意 UDP を設計に入れる前に、ここの確定事実を
押さえれば「やってみたら通らなかった」を回避できる。**机上で断定せず、まず
[`scripts/probe-egress.sh`](scripts/probe-egress.sh) を 1 本流して実測する** のが鉄則。

## 確定事実 (実測済み)

| プローブ | 結果 | 意味 |
|---|---|---|
| UDP STUN 往復 (`stun.l.google.com:19302` / `stun.cloudflare.com:3478`) | **全 timeout** | UDP が一切返らない。ICE が host/srflx candidate を集められず UDP TURN も不可 |
| TCP 443 への生バイト | HTTP レスポンスが返る (`0x4854`=`"HT"`) | 443 は HTTP-aware proxy が横取り |
| **TLS 443 の証明書 issuer** (任意ホスト) | `O=Anthropic, CN=Egress Gateway SDS Issuing CA (production)` | **全 TLS を egress gateway が MITM 終端・再暗号化** |
| TCP 3478 / 5349 (標準 TURN ポート) | block | TURN over TLS の標準ポートも不通 |

到達可能なのは実質 **TCP 443 のみ、かつその TLS は egress gateway で再終端**される。
これは特定ホストの話ではなく **egress 全域** (`api.cloudflare.com` も `www.google.com` も
同じ Anthropic Egress CA が出る)。

## ここから機械的に導ける結論

### 1. WebRTC / P2P 直結 / TURN は CCoW から不成立

- UDP が無い → ICE candidate gathering が成立しない (host / srflx / relay いずれも)
- 標準 TURN ポート block + 443 TLS は egress 終端 → **TURN over TLS を proxy 越しに
  トンネルできない**。**Cloudflare Realtime TURN を使っても同じ** (UDP 不在 + egress 終端)
- 「TURN にフォールバックすれば届く」も成立しない (上記)

> P2P 直結が欲しい場合、CCoW では不可。**ローカル実行 (手元の Claude Code CLI)** なら
> MCP server もブラウザも同一マシン/LAN 内で、そもそも中継不要 = 直結になる。

### 2. transport 層の暗号化は「中継から中身を守る」用途には効かない

CCoW からの **全 TLS は Anthropic egress gateway が終端**する。つまり Cloudflare 等の
中継だけでなく **egress gateway も平文を見られる位置にいる**。コンテナ視点では中継者が
2 者 (egress + 目的の中継) に増え、**TLS / DTLS では中継から中身を守れない** (どちらも
再終端されるため)。

### 3. 「中継に中身を見せない」を満たすのはアプリ層 E2E のみ

payload bytes を **transport に乗せる前に端点で暗号化** (例: AES-256-GCM、鍵は中継を
一度も通らない out-of-band passphrase から HKDF) すれば、ciphertext は egress にも目的
中継にも不透明。TLS 終端の有無に依存しない。**鍵材料に中継が mint した値
(例: server 発行の pairing code / session token) を使うとその中継が復号できてしまい
E2E にならない** — 鍵は中継を通らない秘密に限る。

## 60 秒 probe

設計判断の前に必ず実測する:

```sh
bash scripts/probe-egress.sh
```

[1] UDP STUN 往復 / [2] TLS issuer (egress MITM 検知) / [3] 標準 TURN ポート を順に見て、
末尾の「判定の読み方」で WebRTC 可否を確定させる。**`nc -u -z` の "succeeded" は
connectionless send の成功にすぎず UDP 到達の証明にならない** ので、UDP 可否は必ず
STUN 往復 (= [1]) で判定すること。

## 単発で確認したい時のワンライナー

```sh
# UDP が通るか (STUN 往復)
python3 -c 'import socket,struct,os;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(4);s.sendto(struct.pack(">HHI",1,0,0x2112A442)+os.urandom(12),("stun.l.google.com",19302));print("UDP OK",s.recvfrom(64)[1])'

# TLS を誰が終端しているか (issuer に egress が出たら MITM)
echo | openssl s_client -connect api.cloudflare.com:443 -servername api.cloudflare.com 2>/dev/null | openssl x509 -noout -issuer
```

## 適用が早い兆候

- 「CCoW から P2P / WebRTC / 直結したい」と言われた → **まず本 skill。不成立を即答できる**
- 「中継 (Cloudflare 等) に画面/操作の中身を見せたくない」 → transport 暗号化ではなく
  アプリ層 E2E に誘導 (理由は §2/§3)
- WebRTC/STUN/TURN を組んだら繋がらない → probe で UDP 全滅 or egress MITM を確認して
  原因を transport ではなく環境に帰着させる

## 参照

- 実測の初出: ippoan/cdp-relay#9 (CDP 往復を中継に見せない設計の Phase 0 到達性 gate)
- 関連: `ippoan-infra-map` (CCoW 基盤 5 repo の構造)
