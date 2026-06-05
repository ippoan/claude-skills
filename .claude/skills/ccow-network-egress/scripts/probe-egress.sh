#!/bin/bash
# probe-egress.sh — CCoW (Claude Code on the Web) コンテナの outbound 到達性を実測する。
#
# 「この環境から WebRTC / P2P / 任意 UDP / 生 TLS が通るか」を 60 秒で判定する。
# WebRTC + TURN や P2P 直結を設計する前にこれを 1 本流せば、机上で悩まず可否が確定する。
#
# 使い方:  bash probe-egress.sh
# 依存:    python3, openssl, nc (どれも CCoW コンテナに標準で入っている)
set -u

PASS="OK "; FAIL="NG "; WARN="?? "
echo "=== CCoW egress probe ==="

# ── 1. UDP round-trip (STUN) ────────────────────────────────────────────────
# WebRTC の ICE は UDP の往復が前提。STUN binding request を投げて応答が返るか見る。
# 返らなければ host/srflx candidate を集められず、UDP TURN も不可 = WebRTC 不成立。
echo; echo "[1] UDP STUN round-trip (WebRTC ICE の前提)"
python3 - <<'PY'
import socket, struct, os, time
def stun(host, port, timeout=4):
    pkt = struct.pack('>HHI', 0x0001, 0, 0x2112A442) + os.urandom(12)
    t0 = time.time()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(timeout); s.sendto(pkt, (host, port))
        s.recvfrom(2048)
        print(f"  OK  {host}:{port}/udp  resp ({time.time()-t0:.2f}s) — UDP が通っている")
        return True
    except Exception as e:
        print(f"  NG  {host}:{port}/udp  {type(e).__name__} — UDP 不通")
        return False
ok = stun('stun.l.google.com', 19302) | stun('stun.cloudflare.com', 3478)
print("  => UDP", "通る (WebRTC の芽あり)" if ok else "全滅 (WebRTC/P2P/UDP-TURN 不可)")
PY

# ── 2. TLS を誰が終端するか (egress MITM 検知) ───────────────────────────────
# CCoW は forward proxy 環境。443 への TLS が本物の相手に届くか、それとも egress
# gateway が MITM 終端しているかを、提示証明書の issuer で見分ける。
# issuer が "Anthropic ... Egress Gateway" なら、生の TLS/DTLS は端点まで届かない。
echo; echo "[2] TLS issuer (egress が TLS を MITM 終端していないか)"
for host in turn.cloudflare.com api.cloudflare.com www.google.com; do
  issuer=$(echo | timeout 12 openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null)
  if [ -z "$issuer" ]; then
    echo "  $WARN $host:443  TLS handshake failed"
  elif echo "$issuer" | grep -qi "egress"; then
    echo "  $FAIL $host:443  $issuer"
    echo "       ^ egress gateway が MITM 終端 = 生 TLS/DTLS は端点に届かない"
  else
    echo "  $PASS $host:443  $issuer (passthrough)"
  fi
done

# ── 3. 非 443 ポート / 標準 TURN ポート ──────────────────────────────────────
# TURN over TLS の標準ポート (5349) / TURN/STUN (3478) が開いているか。
echo; echo "[3] 非 443 / 標準 TURN ポート"
for hp in "turn.cloudflare.com 5349" "turn.cloudflare.com 3478"; do
  set -- $hp
  if timeout 6 nc -z -w5 "$1" "$2" 2>/dev/null; then
    echo "  $PASS $1:$2  reachable"
  else
    echo "  $FAIL $1:$2  block"
  fi
done

cat <<'NOTE'

=== 判定の読み方 ===
- [1] が全滅 かつ [2] が egress MITM:
    -> WebRTC / P2P 直結 / TURN (Cloudflare Realtime TURN 含む) は CCoW から不成立。
    -> transport 層の暗号化 (TLS/DTLS) は egress 再終端でコンテナ視点から中継を守れない。
    -> 「中継に中身を見せない」を満たすのは アプリ層 E2E (payload を transport 前に暗号化) のみ。
- [1] に応答あり:
    -> UDP が通る環境 (ローカル実行など)。WebRTC を再検討する価値あり。

注: `nc -u -z` は connectionless socket の send 成功を "success" と誤報する。
    UDP 可否は必ず [1] の STUN 往復で判定すること (この script はそうしている)。
NOTE
