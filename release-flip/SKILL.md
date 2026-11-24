---
name: release-flip
description: タグリリースの CI (配信) が終わるのを待ってから、Release Wave の「切り替え待ち (pending flip)」を 100% に flip する手順。ユーザーが「おわったら flip」「デプロイ終わったら flip」「flip して」「本番に切り替えて」「pending を flip」と言ったとき、または PR merge 後にリリースを本番トラフィックへ出すときに使う。タグを打ち直さない・polling しない・成否を断言しない、の 3 点を含む。
---

# release-flip — 配信が終わったら pending を flip する

## 前提 (ここを間違えると二重リリースになる)

- **merge するとタグは自動で切られる** (Tag Release が main の CI 完了後に走り `v0.0.N` を push)。
  **`create_tag_release` を自分で打たない。** 打つと同じ commit に `v0.0.N+1` がもう 1 本切られ、
  配信 CI が全部二重に走る (2026-11-24 に nuxt-dtako-admin で実際に踏んだ: v0.0.846 と v0.0.847 が同じ `a41f3e6`)。
  ユーザーが「打って」と言っても、まず下の 1 でタグが既にあるかを見る。あれば「既に切れている」と返して打たない
- 配信 CI は **新しい version を 0% (no-traffic) で上げるだけ**。100% に出すのが flip
- 自動 flip は全 repo 共通の compat gate で止まることがある (memory `release-wave-global-compat-gate`)。
  止まっていても手動 flip はできる
- Release Wave の run 名 `release-wave-traffic-rollback` は通常ステップでロールバックではない

## 手順

### 1. 対象のタグと配信 run を特定する

```bash
git ls-remote --tags origin 'v*' | sort -t. -k3 -n | tail -4          # 最新タグと ^{} の commit
gh run list -R <owner/repo> -L 15 \
  --json databaseId,workflowName,headBranch,status,conclusion,createdAt \
  -q '.[]|[.databaseId,.workflowName,.headBranch,.status,.conclusion]|@tsv'
```

`headBranch` がタグ名 (`v0.0.N`) の run が配信 (CI / 各 worker)。同じ commit にタグが 2 本あれば、
**新しい方だけ**を待てばよい (flip されるのは最後に上がった version)。

### 2. 終わるまで待つ (polling しない)

background の Bash 1 本で `gh run watch` を順に待つ。終われば通知で起こされる。`sleep` ループや
`gh run list` の繰り返しはしない。

```bash
for id in <run id ...>; do gh run watch $id -R <owner/repo> --exit-status >/dev/null 2>&1; echo "$id exit=$?"; done
```
(`run_in_background: true`)。**どれかが exit≠0 なら flip しない** — 失敗した run 名と URL をユーザーへ上げて止まる。

### 3. 切り替え待ちを読む

ci-dashboard connector の `release_wave_pending_state` を `{ repo: "<owner/repo>" }` で呼ぶ。
各行の `worker_name` / `tag` / `flippable` を見る。

- 期待したタグが出ていない → 配信の報告がまだ届いていない。数分おいて 1 回だけ読み直す (それでも無ければ報告して止まる)
- `flippable: false` / tag 無し (未tag) の行は flip しない。理由を添えて報告

### 4. flip する

`flippable` な行ごとに `release_wave_pending_flip` を `{ repo, worker_name }` で呼ぶ
(single-worker の repo は `worker_name` を省く)。monorepo は worker ごとに 1 回ずつ。

### 5. 結果を確かめてから言う

flip は GitHub Actions (Release Wave) で走り、呼び出しの応答は成否を返さない。
**「flip しました」と断言しない。**

- Release Wave の run の完了を 2 と同じやり方で待つ (`workflow=Release Wave` の run は ref が付かない)
- もう一度 `release_wave_pending_state` を読み、その行が消えたことを確かめてから「100% になった」と報告する
- 本番の画面で確かめるのは別 (`post-pr-verify` skill)

## 報告の形

途中経過 (queued ⇄ running) は会話に出さない。報告は次の 1 回だけ:
「v0.0.N (commit) を flip しました — <worker> が切り替え待ちから消えたのを確認」か、
止まった理由 (失敗した run / flippable でない行) とその URL。
