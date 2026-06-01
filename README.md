# claude-skills

`ippoan` プロジェクト向けの共有 Claude Code スキル集。

> `yhonda-ohishi/claude-skills` から移行。secret 値や内部インフラの詳細を埋め込んでいたスキル (`secrets.md`, `supabase-r2`, `incus-sandbox`, `wt-quick`, `secret-rotate-pipe`, `dev-proxy-debug`) は移行時に意図的に除外した。

各スキルは `SKILL.md` を含むディレクトリ単位で配置されている。このリポジトリをプロジェクトとして開くと、全スキルが `/<skill-name>` で利用可能になる。

## スキル一覧

- **open-multirepo** — 複数リポジトリと任意のプロンプトを事前アタッチした `claude.ai/code` の起動 URL を生成する。使い方: `/open-multirepo <repo1>, <repo2>, ... — <optional prompt>`
- **check-issue** — GitHub issue を確認してトリアージ用のコンテキストを抽出する。
- **pr-push** — リポジトリの規約に従って PR を作成・push する。
- **pr-subscribe** — `subscribe_pr_activity` 経由で、現在の CCoW セッションを PR の活動 (CI 失敗 / コメント / レビュー) に購読させる。PR イベントでセッションが再起動される (cc-relay #69)。PR URL / `owner/repo#N` を渡す。未指定時は user に確認する。使い方: `/pr-subscribe <PR URL>`
- **wt-direct-push** — worktree から直接 push するワークフロー。
- **worktree-cleanup** — 古い worktree を一括掃除する。
- **tag-release** — タグ/リリースを安全に切る。
- **ci-init** / **ci-cache-patterns** — CI のブートストラップ・キャッシュパターン補助。
- **gh-actions-phantom-permission** — `GITHUB_TOKEN` の無効な permission スコープ (例: `administration: write` は workflow-token ではなく fine-grained PAT のスコープ) が原因の GitHub Actions "phantom 0-job failure" run のデバッグ。
- **coverage-check** / **coverage-test-patterns** — カバレッジゲートとテストパターン。
- **migrate-test** — リポジトリ移行のテスト補助。
- **npm-supply-chain** — npm サプライチェーンチェック。
- **memory-prune** — 古い memory エントリを整理する。
- **large-codebase-setup** — Anthropic の "large codebases" ブログ記事の 3 本柱 (階層 CLAUDE.md / Stop hook による自己反省 / LSP 統合) をリポジトリに適用する。
- **ippoan-infra-map** — CCoW 基盤 5 repo (claude-md / claude-hooks / mcp-relay-rs / cc-relay / mcp-cf-workers) の構造・役割・依存方向と「どの repo に何を足すか」を 1 枚にまとめた situational reference。
- **wrangler-logs** — Cloudflare Workers のログを tail・検索する。
- **cdp-browser** — CDP 経由でブラウザを操作する。
- **egov-api** / **egov-spec** — e-Gov API ヘルパー。
- **ref-files-bulk** — ref-files MCP の `folder_download_url` で folder 配下を tar.gz で一括取得 → `/tmp/` に展開して通常の Read で読むスキル。`file_get` を 1 つずつ呼ぶ token 浪費を避ける。
- **mcp-user-setup** — Cloudflare Worker-native MCP server (`ref-files-worker /mcp` 等) を `~/.claude.json` の user-scope `.mcpServers` に手動 attach するスキル。CCoW では `session-start-write-mcp-user-scope.sh` hook が自動実行するため、ローカル dev / 別環境 / hook skip 時の手動 fallback。
- **eml-read** — `.eml` (RFC822 メール) を人間可読化するスキル。MIME ヘッダ (RFC2047 `=?UTF-8?B?...?=`) を decode し本文を charset 解決、添付を保存。PPAP (パスワード付き zip + パスワード別メール) の受領にも対応。`ref-files-bulk` で落とした `.eml` をそのまま Read すると読めないため、その前段で使う (相補的)。
- **nuxt-vitest** / **worker-vitest** — Nuxt / Workers 向け Vitest ハーネス。
- **type-safe-pipeline** — 型安全なデータパイプラインの足場を作る。
- **verify-env** — 環境変数を検証する。
- **repo-migrate** / **package-publish-debug** — リポジトリ・パッケージ関連のその他ツール。

スキルではない単独の markdown ノート: `backend-check.md`, `bazel-rust.md`, `compare-pdf.md`, `smart-read.md`。

## ディレクトリ構成

```
.claude/skills/<name>/SKILL.md   # プロジェクトレベルのスキル (推奨パス)
<name>/SKILL.md                  # 旧来の top-level レイアウト (引き続きサポート)
```

新しいスキルは `.claude/skills/<name>/SKILL.md` を使うこと。

## 別リポジトリからスキルを使う

これらのスキルがプロジェクトレベルで使えるのは、このリポジトリで Claude Code セッションを起動した時だけ。別リポジトリ (例: `ippoan/auth-worker`) から使う場合は以下のいずれかを選ぶ。

- **(推奨) SessionStart hook で自動インストール** — `yhonda-ohishi/claude-hooks` の [`session-start-install-skills.sh`](https://github.com/yhonda-ohishi/claude-hooks/blob/master/session-start-install-skills.sh) を `~/.claude/settings.json` に登録する。`claude-skills` と `claude-hooks` を `~/.claude/sources/` に shallow clone し、各 `SKILL.md` を `~/.claude/skills/<name>` にシンボリックリンクする (冪等、TTL 1 時間)。一度実行すれば、以降の全セッションで上記スキルが利用可能になる。

  ```jsonc
  {
    "hooks": {
      "SessionStart": [
        {
          "hooks": [
            { "type": "command", "command": "/home/<you>/.claude/hooks/session-start-install-skills.sh", "timeout": 30 }
          ]
        }
      ]
    }
  }
  ```

  環境変数とテストの詳細は [claude-hooks README](https://github.com/yhonda-ohishi/claude-hooks#session-start-install-skillssh-詳細) を参照。

- 対象の `SKILL.md` を別リポジトリの `.claude/skills/<name>/` にコピーする
- `claude-skills` をプラグインとして公開し、`.claude/settings.json` で有効化する
