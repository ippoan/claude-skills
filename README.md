# claude-skills

Shared Claude Code skills for `ippoan` projects.

> Migrated from `yhonda-ohishi/claude-skills`. Skills that embedded secrets or
> internal-infrastructure details (`secrets.md`, `supabase-r2`, `incus-sandbox`,
> `wt-quick`, `secret-rotate-pipe`, `dev-proxy-debug`) were intentionally left
> behind during the migration.

Skills live in per-directory folders containing a `SKILL.md`. When this repo is opened as a project, every skill becomes available via `/<skill-name>`.

## Skills

- **open-multirepo** — Generate a `claude.ai/code` launch URL that pre-attaches multiple repositories and an optional prompt. Usage: `/open-multirepo <repo1>, <repo2>, ... — <optional prompt>`
- **check-issue** — Inspect a GitHub issue and surface context for triage.
- **pr-push** — Create and push a PR following repo conventions.
- **pr-subscribe** — Subscribe the current CCoW session to a PR's activity (CI failure / comment / review) via `subscribe_pr_activity`, so the session is re-woken on PR events (cc-relay #69). Takes a PR URL / `owner/repo#N`; asks the user if none is given. Usage: `/pr-subscribe <PR URL>`
- **wt-direct-push** — Worktree-based direct-push workflow.
- **worktree-cleanup** — Clean up stale worktrees.
- **tag-release** — Cut a tag/release safely.
- **ci-init** / **ci-cache-patterns** — CI bootstrap and cache pattern helpers.
- **gh-actions-phantom-permission** — Debug GitHub Actions "phantom 0-job failure" runs caused by invalid `GITHUB_TOKEN` permission scopes (e.g. `administration: write`, which is a fine-grained PAT scope, not a workflow-token scope).
- **coverage-check** / **coverage-test-patterns** — Coverage gates and patterns.
- **migrate-test** — Repo migration test helper.
- **npm-supply-chain** — npm supply-chain checks.
- **memory-prune** — Prune stale memory entries.
- **large-codebase-setup** — Apply the Anthropic "large codebases" blog 3 pillars (hierarchical CLAUDE.md, Stop hook self-reflection, LSP integration) to a repo.
- **wrangler-logs** — Tail and search Cloudflare Workers logs.
- **cdp-browser** — Drive a CDP-controlled browser.
- **egov-api** / **egov-spec** — e-Gov API helpers.
- **nuxt-vitest** / **worker-vitest** — Vitest harnesses for Nuxt and Workers.
- **type-safe-pipeline** — Type-safe data pipeline scaffolding.
- **verify-env** — Verify environment variables.
- **repo-migrate** / **package-publish-debug** — Misc repo/package tooling.

Standalone markdown notes (not skills): `backend-check.md`, `bazel-rust.md`, `compare-pdf.md`, `smart-read.md`.

## Layout

```
.claude/skills/<name>/SKILL.md   # project-level skills (preferred path)
<name>/SKILL.md                  # historic top-level layout (still supported)
```

New skills should use `.claude/skills/<name>/SKILL.md`.

## Using these skills in other repos

The skills become project-level only when a Claude Code session is launched on this repo. To use them from another repo (e.g. `ippoan/auth-worker`), pick one:

- **(Recommended) Auto-install via SessionStart hook** — register [`session-start-install-skills.sh`](https://github.com/yhonda-ohishi/claude-hooks/blob/master/session-start-install-skills.sh) from `yhonda-ohishi/claude-hooks` in `~/.claude/settings.json`. It shallow-clones `claude-skills` + `claude-hooks` into `~/.claude/sources/` and symlinks every `SKILL.md` into `~/.claude/skills/<name>` (idempotent, TTL 1h). After it runs once, all skills listed above are available in every session.

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

  See [claude-hooks README](https://github.com/yhonda-ohishi/claude-hooks#session-start-install-skillssh-詳細) for env vars and tests.

- Copy the relevant `SKILL.md` into that repo's `.claude/skills/<name>/`, or
- Publish `claude-skills` as a plugin and enable it via `.claude/settings.json`.
