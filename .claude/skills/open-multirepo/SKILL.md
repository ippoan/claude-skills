---
name: open-multirepo
description: Generate a claude.ai/code launch URL that pre-attaches multiple repositories and an optional prompt. Use when the user wants to spawn a Claude Code on Web session that needs cross-repository access (e.g. coordinating changes between ippoan/auth-worker and ippoan/cc-relay) from a GitHub issue or PR.
---

# open-multirepo

Generate a `claude.ai/code` launch URL with multiple repos pre-attached.

## Arguments

User input may include:
- **Repositories**: comma-separated `owner/repo` list (optional). Examples:
  - `ippoan/auth-worker, ippoan/cc-relay`
  - `all` / `*` / 省略 → "Default repo set" を使う (下記参照)
- **Prompt**: free-form text describing what the new session should work on (optional)
- **Issue / PR ref**: e.g. `ippoan/auth-worker#130` — if present, include it in the generated prompt for context

If the prompt is missing AND the user did not provide repos explicitly, ask via `AskUserQuestion`.

## Default repo set — **ALWAYS the full MCP scope unless user passes an explicit list**

> **Hard rule.** Default = attach **every repo the current session has GitHub MCP scope for**. Never narrow this default based on which repos the user happens to mention in the prompt text. Narrowing is allowed **only** when the user passes an explicit comma-separated list of `owner/repo` entries as the repos argument.

The active scope is declared in the system prompt under "Your GitHub MCP tools are restricted to the following repositories". Read it from there and use that exact list — do NOT hardcode repo names in the skill output, since the scope changes per session.

Rationale: cross-repo tasks often need more repos than the user names explicitly (e.g. a PR in repo A needs the consumer in repo B for verification + a shared hook repo C for tooling). Defaulting to "everything the agent already has access to" matches what worked in practice for the cc-relay Phase F acceptance and removes a guess-the-deps step from the user.

If the system prompt's restriction block is missing (rare — open-scope session), ask the user explicitly which repos to attach.

### Distinguishing **explicit list** vs **descriptive mention**

This is the failure mode that breaks the skill, so be careful:

| User input | Classification | Attached repos |
|---|---|---|
| `ippoan/auth-worker, ippoan/cc-relay — fix bug` | **explicit list** (comma-separated `owner/repo` BEFORE any prose) | only those 2 |
| `repos=ippoan/auth-worker,ippoan/cc-relay fix bug` | **explicit list** | only those 2 |
| `PR #18 が merge された ippoan/claude-md と関連 hook repo (yhonda-ohishi/claude-hooks) を attach した URL` | **descriptive mention** (repo names appear inside narrative prose to give context) | **全 MCP scope** |
| `ippoan/cc-relay#37 の続き` | **descriptive mention** (issue ref, not a list) | **全 MCP scope** |
| `all`, `*`, `全部`, repos 引数 省略 | **default** | **全 MCP scope** |

Heuristic: if removing the named repos from the user input still leaves a coherent task description, they were descriptive context, not an exclusivity constraint. **When in doubt, use the full MCP scope.** Over-attaching is harmless (extra repos in the side panel); under-attaching breaks the new session's ability to verify cross-repo work and forces the user to re-launch.

## Prompt body — **MUST stay minimal (spec lives in an issue, not the URL)**

> **Hard rule.** The `prompt=` payload MUST NOT embed the task spec, AND every
> `/open-multirepo` invocation MUST land on a GitHub issue/PR before emitting
> the launch URL. The issue is the durable handover artifact — chat history is
> ephemeral, the spec must live somewhere a future session can read.
>
> 1. **Identify or create the spec issue/PR FIRST** (this step is non-skippable,
>    even for "short" task descriptions — see below for why short ≠ skip):
>    - If the user passed an issue/PR ref (`<owner>/<repo>#<N>`), use that as the
>      target; confirm via `mcp__github__issue_read` that the body covers the
>      current task. If it's stale, update it via `mcp__github__issue_write`
>      with `method: "update"`.
>    - If the user did NOT pass a ref, create a new issue via
>      `mcp__github__issue_write` with `method: "create"`. Title = short task
>      label. Body = the actual spec (current state, what to do, branch ref,
>      acceptance criteria, related PR/issue links).
> 2. Build the launch URL with a one-liner `prompt=` that just references the
>    issue, e.g. `ippoan/auth-worker#157 を read してチェックリストを順に処理。全 repo branch <branch>。`
> 3. **Embed the launch URL into the issue body** under a `## 起動` /
>    `## Launch` heading via `mcp__github__issue_write` with
>    `method: "update"`. This is what makes the issue a self-contained
>    handover — without it, the user has to scroll back through chat to
>    re-launch, and a stale chat or a wiped session means the URL is gone.
> 4. Then print the URL to chat as the final output (per "Output" section).

Why MUST, not "recommend":

- Long prompts make the original URL longer than GitHub markdown can render as a clickable link. Even short prompts under 1500 chars empirically fail (observed: 1189-char URL with 11-repo scope + 145-char prompt rendered as plain text on `ippoan/auth-worker#155` 2026-05-20). Since we always pipe through TinyURL anyway (see "Shortener is mandatory" below), keeping `prompt=` minimal is the only way the **fallback to the raw URL copy/paste path** (TinyURL down, blocked, or unwanted third-party hop) actually works.
- Long prompts duplicate spec content between chat and any future issue/PR, leading to drift the moment one side is edited.
- The new session opens the referenced issue via GitHub MCP tools anyway — embedding the spec in `prompt=` saves zero round-trips.
- A 1-line prompt + issue ref + issue-embedded launch URL is what worked for `ref-files-mcp-server-rs#4` (Phase 2 共通化, 2026-05-19). The 1712-char "embed everything in `prompt=`" alternative violates this rule and was rolled back.

### Why "short prompt" doesn't exempt issue creation

Past sessions skipped step 1 (issue creation) when the user's task description
looked "short enough" (~120 chars), reasoning that the inline prompt body
captured the intent. This is wrong, for two reasons:

- **Discoverability**: the launch URL only exists in chat history. Chat
  compacts/expires/gets wiped, and the new session has no path back to the
  launch URL except via the user re-typing it. A dedicated issue is the
  permanent record.
- **Re-launch + iteration**: tasks routinely need a 2nd / 3rd launch (CI
  failed, partial completion, follow-up review). Without a tracking issue,
  each re-launch requires reconstructing the spec from chat. With one, it's
  a click on the URL embedded in `## 起動`.

The 200-char threshold below applies to the `prompt=` query-string body, NOT
to "do I need an issue". Issue creation is always required; the threshold
just bounds how much can be inlined into the URL itself.

Acceptable inlined `prompt=` shapes (≤200 chars):

- `Phase F acceptance test` — single-line task name (still needs a backing issue)
- `ippoan/cc-relay#37 の続き` — issue ref only
- `<owner/repo>#<N> を read してチェックリストを順に処理。全 repo branch <branch-name>。`
- `Fix <owner/repo>#<N>; design in issue body, out of scope: <one phrase>.`

Disallowed shapes — skill MUST refuse and instead ask the user where to land the spec:

- Multi-paragraph design rationale
- Bulleted work breakdowns covering multiple repos
- Architecture trade-off tables
- Step-by-step acceptance checklists

Flow for any user input (short or long):

1. **Did the user pass an issue/PR ref?** (e.g. `auth-worker#157`)
   - **Yes** → use it as the target. Confirm via `issue_read` that the body
     covers the current task. If stale, update via `issue_write` (method:
     update). Skip to step 2.
   - **No** → create a new issue via `issue_write` (method: create) in the
     most relevant repo (inferred from the prompt; if ambiguous, prefer the
     repo that owns the bulk of the work — `AskUserQuestion` if truly
     ambiguous). Title = short task label. Body = full spec.
2. Build the launch URL referencing the issue.
3. Patch the issue body via `issue_write` (method: update) to embed the URL
   under `## 起動` (Japanese-default sessions) or `## Launch` (English).
4. Print the URL to chat (per "Output" section).

## Behavior

1. Resolve repo list:
   - **Explicit list** (comma-separated `owner/repo` passed as the repos argument, not embedded in prose) → trim each entry, validate `^[^/\s]+/[^/\s]+$`, drop empties.
   - **Descriptive mention** of repo names inside the prompt → ignore for scope purposes, treat as default-path.
   - `"all"` / `*` / `全部` / 省略 / 判断つかない → read from system prompt "restricted to the following repositories" block.
2. **Land the spec on a GitHub issue/PR (mandatory, never skip)**:
   - If the user input contains an issue/PR ref (`<owner>/<repo>#<N>`), treat
     that as the target. Verify body coverage via `mcp__github__issue_read`;
     update via `mcp__github__issue_write` (method: update) if stale.
   - Otherwise, create a new tracking issue via `mcp__github__issue_write`
     (method: create) in the most-relevant repo (inferred from the prompt; if
     truly ambiguous, ask via `AskUserQuestion`). Title = short task label;
     body = the full spec (current state, what to do, branch ref if any,
     acceptance criteria, related PR links).
   - This step runs BEFORE URL construction so the URL can reference the
     resulting issue number.
3. Build the URL:
   - Base: `https://claude.ai/code`
   - `repositories=` — comma-separated repos, **NOT** URL-encoded commas (claude.ai/code accepts raw `,`)
   - `prompt=` — `encodeURIComponent` the full prompt text. The prompt MUST
     reference the issue from step 2 (e.g. `<owner>/<repo>#<N> を read して...`),
     not embed the spec inline.
4. **Always shorten the URL via TinyURL** (no length check — see "Why always-shorten" below):
   ```bash
   SHORT=$(curl -sS "https://tinyurl.com/api-create.php?url=$(node -e "console.log(encodeURIComponent(process.argv[1]))" -- "$URL")")
   ```
   Verify the redirect target matches before emitting. If TinyURL is unreachable
   (network error, non-200 response, body not starting with `https://tinyurl.com/`),
   fall back to the raw URL and add a `⚠ TinyURL unreachable, raw URL may not render as a link in GitHub` note to chat output and issue body.
5. **Patch the issue body to embed the (shortened) URL** via `mcp__github__issue_write`
   (method: update). Insert under a `## 起動` heading (Japanese-default
   sessions) or `## Launch` (English) at the top of the body, so the URL is
   the first thing a future reader sees. Use this format:
   ```markdown
   ## 起動

   [🚀 <short label>](<short_url>)

   <details><summary>raw URL</summary>

   ```
   <original-claude.ai/code-url>
   ```

   </details>

   > 短縮 via tinyurl.com (always-shorten policy, see open-multirepo skill)
   ```
6. Output to chat:
   - A short H3 heading summarising the prompt's intent, followed by a plain Markdown link: `### 🚀 [<short label>](<short_url>)`. The heading + emoji prefix gives visual weight without relying on external images.
   - The attached repos as a short bullet list under the link, so the user can verify scope at a glance.
   - A 1-line note pointing to the tracking issue created/updated in step 2
     (e.g. `Spec / handover: <owner>/<repo>#<N>`).
   - The raw prompt body as a fenced code block (for re-running / editing).
   - The raw `claude.ai/code` URL as a fenced code block (for copy/paste when TinyURL is blocked).
   - A 1-line `> 短縮 via tinyurl.com` disclosure.
7. **Do NOT** post the URL to any other surface automatically (Slack, comment
   on unrelated PRs, etc). The chat output + the tracking issue body are the
   only two places the URL lives by default.

## Why a plain Markdown link, not a badge image

shields.io / image-link badges were tried (`[![label](https://img.shields.io/...)](url)`) but they fail in the most common consumer surface — **claude.ai chat does not auto-load external images** and renders the badge as a `画像を表示 / Show image` placeholder card instead of a button. The image-link is technically navigable but the user has to click "show image" first, defeating the one-click goal. GitHub PR/issue UI does load shields.io, but optimising for that at the cost of in-chat usability is a bad trade — chat is where launch URLs are generated.

A plain `[🚀 <label>](<url>)` link renders as a clickable hyperlink in every Markdown surface (claude.ai chat, GitHub, VS Code preview, Slack) without external fetches. The H3 wrapping and emoji prefix carry the visual emphasis. This is the format the skill stays on.

## Example (default repo set — short task, NEW issue created)

User: `/open-multirepo Phase F acceptance test`

Even though the prompt is short, the skill MUST create a tracking issue first.

Step 1: Create issue via `mcp__github__issue_write`:
- repo: inferred (Phase F is a cc-relay milestone, so `ippoan/cc-relay`)
- title: `Phase F acceptance test`
- body: spec covering current state of Phase F, what acceptance means,
  branch to use, related PRs, etc.
  Result: `ippoan/cc-relay#42` (example new number).

Step 2: Build URL referencing the new issue.

Step 3: Pipe the raw URL through TinyURL → e.g. `https://tinyurl.com/2abcdef9`.

Step 4: Patch issue #42 body to prepend:
```markdown
## 起動

[🚀 Phase F acceptance test](https://tinyurl.com/2abcdef9)

<details><summary>raw URL</summary>

```
https://claude.ai/code?repositories=...&prompt=ippoan%2Fcc-relay%2342...
```

</details>

> 短縮 via tinyurl.com (always-shorten policy, see open-multirepo skill)
```

Step 5: Chat output:

````markdown
### 🚀 [Phase F acceptance test](https://tinyurl.com/2abcdef9)

**Attached repos:**
- ippoan/cc-relay
- ippoan/auth-worker
- ippoan/ci-dashboard
- yhonda-ohishi/claude-hooks
- yhonda-ohishi/claude-skills

Spec / handover: ippoan/cc-relay#42

**Prompt:**
```
ippoan/cc-relay#42 を read して処理
```

**Raw URL** (in case TinyURL is blocked):
```
https://claude.ai/code?repositories=ippoan/cc-relay,ippoan/auth-worker,ippoan/ci-dashboard,yhonda-ohishi/claude-hooks,yhonda-ohishi/claude-skills&prompt=ippoan%2Fcc-relay%2342%20%E3%82%92%20read%20%E3%81%97%E3%81%A6%E5%87%A6%E7%90%86
```

> 短縮 via tinyurl.com
````

## Example (existing issue ref — reuse, don't create new)

User: `/open-multirepo ippoan/auth-worker#167 の coverage 100% 復帰`

User passed an explicit issue ref. Step 1: read auth-worker#167 via
`mcp__github__issue_read` to confirm its body covers the coverage recovery
task. If yes, reuse #167 as the target — don't create a new issue. If the
body doesn't yet cover this specific task, append a `## 起動: coverage 100% 復帰`
section to the existing body via `issue_write` (method: update).

Step 2: build URL referencing #167 in the prompt.

Step 3: patch #167 body to add the launch URL under `## 起動` (if not already
present from a prior invocation).

Chat output (same always-shorten + raw URL + disclosure wrapper as the first example):

````markdown
### 🚀 [auth-worker#167 coverage 100% 復帰](https://tinyurl.com/2xyz1234)

**Attached repos:** (全 MCP scope)
- ...

Spec / handover: ippoan/auth-worker#167

**Prompt:**
```
ippoan/auth-worker#167 の coverage 100% 復帰 — 詳細は issue body 参照
```

**Raw URL** (in case TinyURL is blocked):
```
https://claude.ai/code?repositories=...&prompt=ippoan%2Fauth-worker%23167%20...
```

> 短縮 via tinyurl.com
````

## Example (explicit list — narrowed scope)

User: `/open-multirepo ippoan/auth-worker, ippoan/cc-relay — continue work on auth-worker#130 from cc-relay broker side`

The repo list appears **before** the prose, comma-separated, as the leading argument. Narrow to those 2.

Even though the resulting raw URL is short (~240 chars, well within any historical render-safe range), the skill still pipes through TinyURL — always-shorten is unconditional:

````markdown
### 🚀 [continue work on auth-worker#130](https://tinyurl.com/2abc5678)

**Attached repos:**
- ippoan/auth-worker
- ippoan/cc-relay

**Prompt:**
```
continue work on auth-worker#130 from cc-relay broker side
```
````

## Implementation notes

- This skill takes user input directly — do not call external tools unless needed for clarification.
- Use Node/Bash inline for URL encoding when the prompt contains special chars. `encodeURIComponent` semantics: `%20` for space, `%23` for `#`, `%0A` for newline.
- **CRITICAL — encode `(` and `)` too.** `encodeURIComponent` does NOT touch `!*'()` (RFC 3986 unreserved sub-delims). If the prompt body contains literal `(` or `)` — Japanese prose often does, e.g. `(本 session で作成済)` — those parens land verbatim in the URL, and Markdown's `[text](url)` parser terminates the link at the first unescaped `)`. Visible failure mode: the comment renders as `[label]` plain text followed by a raw URL on the next line (not clickable). **Always** post-process the encoded prompt:

  ```js
  const enc = encodeURIComponent(prompt)
    .replace(/!/g, '%21').replace(/\*/g, '%2A')
    .replace(/'/g, '%27').replace(/\(/g, '%28').replace(/\)/g, '%29');
  ```

  Verify with `/[()]/.test(url) === false` before emitting.

- **CRITICAL — GitHub markdown silently refuses to render long `claude.ai/code` URLs.** Even URLs well under the [documented 4,096 limit](https://github.com/orgs/community/discussions/48174) get rendered as plain text instead of clickable links. Observed failures: 2,241 chars (`auth-worker#157`, 2026-05-19) AND **1,189 chars** (`auth-worker#155`, 2026-05-20 — 11-repo scope + 145-char prompt). Observed working: ~200-500 chars. The trigger is not raw length alone — long query strings with many commas / `%`-encoded chars seem to push the parser over a heuristic limit that's much lower than the documented one.

  **The skill's emit step MUST always shorten the URL via TinyURL** — no length check, no threshold. The previous "shorten only above 1500 chars" rule was unreliable because the empirical limit is well below that and varies per surface (chat vs issue comment vs PR body). Always-shorten removes the guess.

  ```bash
  SHORT=$(curl -sS "https://tinyurl.com/api-create.php?url=$(node -e "console.log(encodeURIComponent(process.argv[1]))" -- "$URL")")
  # SHORT is like https://tinyurl.com/26l6z4o4 (~28 chars)
  ```

  Verify with `curl -sI "$SHORT" | grep -i location:` returns the original before emitting. Always include the original URL in a fenced code block under the link too, so the user can copy/paste manually if TinyURL is ever down or blocked. Disclose the third-party hop in a short note (`"短縮 via tinyurl.com"`) — never silently proxy.

- **Why always-shorten (was: "Shortener is fallback, not default").** Two failure modes the old conditional rule kept hitting:
  1. **Under-threshold failure**: 1,189-char URL fell under the 1,500 threshold, skill emitted the raw URL, GitHub failed to linkify it, follow-up correction comment required (2 round-trips). Always-shorten would have caught it.
  2. **Surface mismatch**: chat may render a 1,000-char URL fine while the same URL pasted into a GitHub issue body doesn't. The skill can't predict the destination surface, so the safe default is to shorten unconditionally.

  Cost of always-shorten: 1 extra HTTP round-trip to `tinyurl.com/api-create.php` per emit (~100 ms). Benefit: zero "didn't render" follow-ups. Keeping `prompt=` minimal (per the **"Prompt body — MUST stay minimal"** hard rule above) is still enforced — it just no longer doubles as a render-safety guarantee.
- If the user does not provide a prompt, omit `&prompt=` entirely.
- If only 1 repo is given (explicitly), the skill still works — but warn that the user could just open the repo directly.
- If the resolved repo list is empty (no explicit input + no scope block found), STOP and ask the user.
- **When unsure whether input is explicit list vs descriptive mention, default to "descriptive" and attach the full MCP scope.** Over-attaching costs nothing; under-attaching forces a re-launch.
