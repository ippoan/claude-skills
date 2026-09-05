---
name: public-text-guard
description: 公開される文 (PR / issue の本文・コメント) と、拒否された tool 呼び出しの中身から、本番識別子 (UUID の device_id / tenant_id)・device credential・資格情報 (ghp_ / sk- / AKIA / BEGIN)・内部ホスト名を機械的に検出する hook 2 本 (PreToolUse / PermissionDenied) と、その唯一のスキャナ。トリガー:「public-text-guard」「PR 本文に識別子」「gh pr create が deny された」「Blocked by classifier」「分類器に拒否された」「auto mode classifier」「PermissionDenied hook」「識別子を消したら通った」「本番 ID をハードコード」「denylist に内部ホスト名」「公開文の検査」等。gh の deny に遭ったとき・公開文へ識別子を書きそうなとき・この hook を導入/調整するときに読む。
---

# public-text-guard — 公開文の識別子検査を hook 2 本で強制する

## 0. 何を解くか (2026-09-05 の実際の事故)

親が `gh pr create` を打ったら分類器に拒否された:

```
Permission for this action was denied by the Claude Code auto mode classifier.
Reason: Blocked by classifier.
```

**親は理由を調べず、ユーザーへ「判断をお願いします」と投げた。** 実際の原因は
**コマンドに埋めた本番の device_id / tenant_id** で、**識別子を消したら同じコマンドが通った**。
`migrations/` には「ハードコードするな」と子に指示しておきながら、親が PR 本文に貼っていた。

塞ぐべき穴は 2 つある。**公開される前**と、**拒否されたのに原因を調べないこと**。

| hook | 効く場面 |
|---|---|
| `PreToolUse` (matcher `Bash`) | **公開される前に止める。** PR / issue 本文は作成した瞬間に公開ページと git 履歴へ載るので、本命の防波堤 |
| `PermissionDenied` | PreToolUse が拾えなかった別要因で拒否されたとき、**原因究明を機械的に強制する**。今回の事故 (原因を調べず人へ投げた) を直接塞ぐ |

## 1. 構成

```
public-text-guard/
  scripts/scan_public_text.py           ← 判定ロジックはここ 1 か所だけ
  scripts/resolve_body_file.py          ← --body-file のパス解決。2 hook が共有
  hooks/pretool-public-text-guard.py    ← PreToolUse / matcher: Bash
  hooks/permission-denied-scan.py       ← PermissionDenied / matcher: *
  tests/run_tests.py                    ← 22 ケース。HOME と gh を差し替えて回す
```

**スキャナは 1 本。** 2 つの hook がどちらもこれを import する。
判定が 2 か所に分かれると必ず食い違い、片方だけ直して忘れる。

### 何を走査対象にするか

`PreToolUse` は `--title` / `--body` / `--body-file` を個別に走査したうえで、
**コマンド全文も必ず走査する**。フラグ解析だけに頼ると、引用が壊れて `shlex` が失敗した
コマンドや heredoc (`--body-file -`) がそのまま素通しし (tests 12〜13)、
`--label` やパイプ前の別コマンドに載る語は**どこからも見えなくなる** (test 21)。
`--title` はフラグ側でも当たるが、**全文走査単体でも当たること**を test 22 で固定してある。

`--body-file` は `resolve_body_file` が**同じコマンド文字列の文脈込みで**開く (#157):

- `SP=…` のような単純な変数代入を拾って `"$SP/pr.md"` / `"${SP}/pr.md"` を展開する
- `cp <src> <dst>` / `mv` / `cat <src> > <dst>` で**直前に作られる**本文は、
  まだ存在しないので**コピー元 `<src>` を読む** (PreToolUse は実行の**前**に走る)

**本文を最後まで読めなかったら deny する (fail-closed)**。deny 文言は
「含まれている」と断定せず、「本文を読めなかったので検査できていない」と、対処
(パスに UUID を含まない場所へ本文を置く / 本文の作成と `gh` を別の Bash 呼び出しに分ける)
を示す。**ここを fail-open にしないこと。** `PermissionDenied` hook は
**PreToolUse が pass した呼び出しには発火しない** (実測)。
「2 段構えだから緩めてよい」は成り立たない。

### 誤爆したときに直す場所 (#157 の教訓)

実運用の 1 本目で 2 回続けて誤爆した。どちらも本番識別子ではなく、
**作業パスに含まれるセッション UUID** (`/tmp/…/<UUID>/scratchpad`) だった。

直したのは**当て方**であって、走査範囲ではない。
「全文を見ているのが悪い」と考えて全文走査を弱めると、上に挙げた
`--label` やパイプ前の語が塞げなくなる。**当たり方の 1 点** —
`_is_path_uuid` (パス様トークンの中の UUID は当てない) — だけを外す。

## 2. 何を当てるか / 当てないか

| 種別 | 当てる | 備考 |
|---|---|---|
| `uuid` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | device_id / tenant_id はこの形。大文字表記も当てる |
| `device-credential` | base64url 20〜24 文字 | 大文字・小文字・数字を**全部**含むものだけ |
| `github-token` | `ghp_` / `gho_` / `github_pat_` | prefix が在れば尻尾が短くても当てる |
| `api-key` / `aws-key` / `private-key` | `sk-…` / `AKIA…` / `-----BEGIN` | |
| `denylist` | state の語 (1 行 1 語) | **内部ホスト名は repo に書かない**。下記 4 節 |

**当てないもの (これが無いと使われなくなる)**:

- **git SHA** — 7 / 40 桁 hex は長さで外れ、20〜24 桁 hex も「16 進のみ」で落ちる
- **プレースホルダ** — `00000000-0000-0000-0000-000000000000` のように 16 進の中身が
  1 種類の文字だけの UUID は、値ではなく形の説明なので除外
- **パス様トークンの中の UUID** — `/tmp/…/<UUID>/scratchpad` のように `/` を含む語の
  一部として出てきた UUID は当てない (#157)。公開文に載る UUID は `device_id=…` のように
  語として立つ。この除外を入れる前は、作業パスの UUID で 2 回続けて誤爆した
- **英単語・kebab-case の識別子** — `internationalization` や `public-text-guard-hook` は
  「大文字・小文字・数字を全部含む」条件で落ちる

実測: この repo の markdown 123 本を通して当たりは 1 件だけで、それは
`cores3-crash-triage/SKILL.md:9` に載っている**本物の実機 device id** だった
(この skill 自身の方針どおり、値はここに再掲しない)。
つまり誤爆 0 件。**この hook が防ぎたかったものが、既に public repo に載っている実例**でもある。

## 3. 単体で使う

```bash
python3 public-text-guard/scripts/scan_public_text.py FILE   # or stdin
# 出力: 行番号:種別:語   当たりが在れば exit 1
```

## 4. denylist (内部ホスト名など)

`~/.claude/state/public-text-guard/denylist` に 1 行 1 語。`#` 始まりはコメント。
無ければ空扱い (この検査だけ効かない)。

**この repo にも、テストにも、hook 本体にも内部ホスト名を書かないこと。**
書いた瞬間、公開 repo に内部ホスト名が載るという、この hook が防ぎたかったものそのものになる。

## 5. escape (誤爆したとき)

```bash
touch ~/.claude/state/public-text-guard/allow/<session_id>
```

が在れば PreToolUse は素通しする。deny の文言にこのパスが出るので、その場でコピーできる。
セッション単位なので、次のセッションでは再び効く。

## 6. `PermissionDenied` で返せるもの (実測、claude 2.1.239)

**設計時に必ず読むこと。** このイベントの `hookSpecificOutput` は
**`{hookEventName, retry?}` しか受け付けない**。`additionalContext` は無い。
stdout は transcript (ctrl+o) 表示のみ、`systemMessage` はユーザー向け UI のみ。
⇒ **当たった語をモデルへ直接返す口が無い。**

そこで 2 本を橋渡ししている:

1. `PermissionDenied` hook が走査結果を
   `~/.claude/state/public-text-guard/pending/<session_id>.txt` へ書き、
   **当たったときだけ `retry: true`** を返す (モデルには
   「The PermissionDenied hook indicated you may retry this tool call.」が届く)
2. 同じセッションの**次の Bash 呼び出し** (= たいていは同じコマンドの再試行) で
   `PreToolUse` hook が pending を回収し、`additionalContext` としてモデルへ渡す
3. 再試行が公開系の `gh` なら、`PreToolUse` が同じスキャナで改めて deny するので、
   そちらの文言にも当たった語と行が出る

分岐の意味そのものは retry ビットが運ぶ:

- **当たった** → `retry: true`。「値を伏せて 1 回だけ再試行せよ」
- **当たらない** → `retry` を返さない。「推測で再試行するな。拒否文言を引用して人へ上げよ」

もう 1 つの実測: このイベントは **auto mode 分類器による deny のときだけ**発火する
(`decisionReason.classifier === "auto-mode"`)。通常の許可確認やユーザーの拒否では回らない。

## 7. 登録 (`~/.claude/settings.json`)

**この repo からは登録しない。** 各自の `~/.claude/settings.json` へ次を追記する。
`<skills>` は `session-start-install-skills.sh` が置いた実体のパス
(既定では `~/.claude/sources/claude-skills`)。

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "<skills>/public-text-guard/hooks/pretool-public-text-guard.py",
            "timeout": 30
          }
        ]
      }
    ],
    "PermissionDenied": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "<skills>/public-text-guard/hooks/permission-denied-scan.py",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

`PreToolUse` の timeout は `gh repo view` の分だけ要る (既定 15 秒でタイムアウトし、
判定できなければ public 扱い = fail-closed)。

### 登録名の綴りを確かめる方法

`/hooks` は対話端末でしか開けない。**`claude doctor` が非対話で同じ検証をする**:

```bash
claude doctor 2>&1 | grep -A3 -i "invalid settings"
```

綴りを間違えると `Unknown hook event "…" was ignored. Valid events: …` が出て、
**有効なイベント名が全部列挙される**。正しく書けていれば `Invalid settings` の節ごと出ない。
(実物の `~/.claude/` を汚さずに試すなら `HOME` を一時ディレクトリにして同じことをする。)

## 8. テスト

```bash
python3 public-text-guard/tests/run_tests.py
```

`HOME` を一時ディレクトリへ、`gh` を stub へ差し替えて回すので、
**`~/.claude/state/` の実物にも本物の GitHub にも触らない**。22 ケース全 PASS で exit 0。
1〜11 は issue #153 の受け入れ条件そのもの、12〜13 はすり抜けの回帰防止、
14〜22 は #157 の誤爆 2 経路と、そこを直しても緩めてはいけない 7 点。

**CI で回る** (`.github/workflows/knowledge-check.yml`)。`public-text-guard/**` を
触る PR で blocking。#157 まではこの repo の python は CI で 1 行も回っていなかった。

## 9. この hook で解けないこと

- **分類器がなぜ拒否したかは分からない。** `reason` は `Blocked by classifier.` 止まり。
  この hook は「同じクラスの原因を先に具体的に挙げる」だけで、分類器の判断は読めない
- **CI の失敗は観測できない** (外部イベント)。あれは Monitor の担当
- `PermissionDenied` は**分類器の deny 専用**。ユーザーが手で拒否したときは回らない
