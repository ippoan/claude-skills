---
name: claude-in-chrome
description: >
  Claude in Chrome (Anthropic 公式 Chrome 拡張) で何ができるか の capability 棚卸しと、
  cdp-pair / cdp-agent / cdp-browser との使い分けガイド。「ブラウザで確認したい」となった
  時に **reflex で cdp-pair に行く前に必ず参照**し、経路を選定する。通常の UI 動作確認
  (画面遷移・表示確認・クリック・コンソールログ) は公式拡張 (Claude Desktop / Cowork 経由)
  が pairing 不要で最速。cdp-relay が必要なのは httpOnly Cookie ログイン委譲・ヘッダ/ボディ
  込み network 解析・生 CDP の 3 領域のみ。CCoW セッション自身は拡張を操作できない
  (ツール未 provision) ため「user に Desktop/Cowork でやってもらう」判断も含む。
  トリガー:「Claude in Chrome」「公式 Chrome 拡張」「claude --chrome」「/chrome」
  「ブラウザで動作確認」「UI 確認 どっちでやる」「手元ブラウザ 経路選定」「staging 目視確認」
  「cdp-pair と 使い分け」「拡張でできること」「list_connected_browsers」
  「read_console_messages」「Cowork からブラウザ」等。
---

# claude-in-chrome — 公式 Chrome 拡張の capability と cdp-pair との使い分け

Claude in Chrome (公式拡張、beta) の Claude Code / Desktop / Cowork 連携が実用になった。
「ブラウザで確認したい」場面での経路選定を、実機検証
([ohishi-exp/nuxt-dtako-admin#196](https://github.com/ohishi-exp/nuxt-dtako-admin/issues/196))
の結果に基づいて定める。

## 結論: 使い分け早見表

| やりたいこと | 使う経路 |
|---|---|
| 画面遷移・表示確認・クリック・フォーム入力・スクリーンショット | **Claude in Chrome** (Desktop / Cowork) |
| コンソールエラー確認・簡易ネットワーク一覧 (URL/method/status) | **Claude in Chrome** |
| CF Access 配下の staging/prod の目視確認 | **Claude in Chrome** (拡張側ブラウザの Google ログインで通過できる。実証済み) |
| **CCoW セッション自身**がブラウザを操作する必要がある | **cdp-pair** (即席は経路 B curated) |
| httpOnly Cookie を使ったログイン委譲 | **cdp-pair** `browser_cookies` (公式拡張は httpOnly を読めない) |
| リクエスト/レスポンスの**ヘッダ・ボディ**込みネットワーク解析 | **cdp-pair 経路 A** (chrome-devtools-mcp passthrough) |
| パフォーマンストレース・火炎グラフ等の本格 devtools | **cdp-pair 経路 A** |
| 大きな値 (localStorage dump 等) を context 経由せず回収 | **cdp-pair** `browser_stash` |

速度感: 公式拡張は **pairing 手順 (code 発行 → popup 貼り → 接続) が丸ごと不要**なので、
「ちょっと画面を見たい」の立ち上がりが cdp-pair より速い。逆に CCoW セッションが
自律ループ (撮る → 見る → 次の操作) を回すなら cdp-pair 一択。

## Claude in Chrome とは (確定事実、2026-07 時点)

- 正式名称: Claude in Chrome browser extension (beta)。
  [Chrome Web Store](https://chromewebstore.google.com/detail/claude/fcoeoabgfenejglbffodgkkbkcdhcgfn)。
  全有償プラン対象。Chrome / Edge のみ (Brave, Arc, Firefox, WSL 非対応)
- 接続経路は**ローカル IPC ではなくクラウドリレー** (`bridge.claudeusercontent.com`) 経由:
  Claude Code/Desktop → cloud relay → Native Messaging Host → 拡張。
  同一マシンでも cloud を経由する (第三者検証報告)

### どの surface から使えるか

| surface | 可否 |
|---|---|
| Claude Desktop | ✅ 公式対応 (`list_connected_browsers` で接続確認 → navigate 等)。実機検証済み |
| ローカル Claude Code CLI / VS Code | ✅ `claude --chrome` または `/chrome`。**Claude Code 2.0.73+ 必須** |
| Claude Cowork | ⚠️ 公式は「Works in Claude Cowork」と明記。ただし既知バグ ([anthropics/claude-code#48806](https://github.com/anthropics/claude-code/issues/48806)) |
| **CCoW セッション (自前 environment)** | ❌ 拡張操作ツールが provision されない。ToolSearch にも出ない |

CCoW セッションで「公式拡張向き」の確認が発生したら、**自分で cdp-pair に行く前に
「この確認は Claude Desktop / Cowork から拡張にやらせた方が速い」と user に提案してよい**。
user が不在 / 自律ループが必要なら cdp-pair に切り替える。

## capability 棚卸し (実機検証 #196 より)

| 機能 | 可否 | 備考 |
|---|---|---|
| ページ遷移・クリック・入力・スクリーンショット | ✅ | 実証済み |
| 要素検索・アクセシビリティツリー (`find` / `read_page`) | ✅ | 自然言語で要素特定 |
| コンソールログ (`read_console_messages`) | ✅ | **pattern 指定必須**、現在ドメインのみ |
| ネットワーク一覧 (`read_network_requests`) | ✅ 簡易 | url / method / statusCode **のみ**。ヘッダ・ボディ・タイミング不可 |
| 任意 JS 実行 (`javascript_tool`) | ✅ | ページコンテキスト。devtools コンソールほぼ同等 |
| Network タブ相当 (ヘッダ/ボディ/ウォーターフォール) | ❌ | JS で `performance.getEntriesByType('resource')` なら transferSize/duration/initiatorType は代替可。クロスオリジン等は `[BLOCKED: Cookie/query string data]` でマスク |
| Performance タブ (トレース/火炎グラフ) | ❌ | `performance.getEntriesByType('navigation')` / `performance.memory` で簡易値のみ代替可 |
| Cookie 一覧 | ⚠️ | 専用ツール無し。`document.cookie` は読めるが **httpOnly は不可** |
| 生 CDP 接続 | ❌ | 不可 |

## gotcha

- **複数マシンに拡張を入れていると、どのマシンで実行されるか不明確**になる報告あり
  (cloud relay がアカウント単位で拡張を解決するため)。検証マシン以外の拡張は
  一時的に無効化しておくと安全
- Cowork からの操作は既知バグあり (anthropics/claude-code#48806)。失敗したら
  Desktop 経由に切り替えるか cdp-pair に fallback
- `read_console_messages` は pattern 未指定だと使えない。まず `.*` 等で広く取る
- CF Access 配下のページは拡張側ブラウザのログイン (Google アカウント選択 →
  ログイン後に目的ページ) がそのまま通る。**Claude 側に credential は渡さない**こと —
  ログイン操作自体は user のブラウザ session に委ねる

## 関連 skill / 記録

- **cdp-pair** — CCoW から手元 Chrome を cdp-relay 経由で操作 (経路 A/B の手順)
- **cdp-agent** / **cdp-browser** — MSI quick tunnel / Tailscale 直結の別経路
- **bun-browser-verify** — 「ビルドは bun・認証付き IO はブラウザ」の分業ハーネス
- 実機検証記録: [ohishi-exp/nuxt-dtako-admin#196](https://github.com/ohishi-exp/nuxt-dtako-admin/issues/196)
  (残調査: Cowork 実機検証 / CCoW への provision watch)
- 公式 docs: <https://code.claude.com/docs/en/chrome> /
  [サポートページ](https://support.claude.com/en/articles/12012173-get-started-with-claude-in-chrome)
