---
name: open-multirepo
description: Generate a claude.ai/code launch URL that pre-attaches multiple repositories and an optional prompt. Use when the user wants to spawn a Claude Code on Web session that needs cross-repository access (e.g. coordinating changes between ippoan/auth-worker and ippoan/cc-relay) from a GitHub issue or PR.
---

# open-multirepo

Generate a launch link that opens a `claude.ai/code` session with multiple
repos pre-attached.

## Launch link = `ci-dashboard /cc` redirect (primary mechanism)

> **Hard rule.** Emit the **`/cc` redirect link**, not a raw `claude.ai/code`
> URL and not a TinyURL.
>
> ```
> https://ci-dashboard.ippoan.org/cc?i=<owner/repo#N>[&r=<owner/repo,...>][&p=<prompt>]
> ```
>
> The endpoint (ippoan/ci-dashboard `src/launch.ts`, issue #214) reconstructs
> the full `claude.ai/code?repositories=...&prompt=...` URL **server-side** and
> 302-redirects. So the link the skill emits stays short (≈60 chars) and
> renders as a clickable hyperlink everywhere — which is the whole reason the
> old flow shortened via TinyURL.

Why this replaced "build full URL → always shorten via TinyURL":

- The full `claude.ai/code` URL is ~1 KB; GitHub / Claude markdown silently
  refuse to linkify URLs that long (observed failures at 1189 chars). `/cc?i=…`
  is short, so it always linkifies.
- **0 round-trip on emit** — the skill just builds a string. No TinyURL
  create call, no redirect-verify call. (The old always-shorten path cost 2
  external round-trips per emit.)
- **No third party** — no `tinyurl.com` hop to disclose, no "TinyURL down /
  blocked" fallback branch.
- **Open-redirect safe** — `/cc` only ever builds a `claude.ai/code` URL;
  `repositories` tokens are validated `owner/repo` and `prompt` is encoded.

### How `/cc` expands the params

| param | required | meaning | omit when |
|---|---|---|---|
| `i` | **yes** | issue/PR ref `<owner>/<repo>#<N>` | never |
| `r` | no | repo set: a comma-separated `owner/repo` list **or** a keyword without `/` (`all`) | **default (full) scope** — the worker attaches its baked-in `ALL_REPOS` |
| `p` | no | custom prompt (verbatim) | **default prompt** — the worker supplies `${i} を read してチェックリストを順に処理。全 repo default branch。` |

So the common case (full scope + "read the issue & process") is just
**`/cc?i=<issue>`** — no `r`, no `p`. Narrowed scope or a custom prompt add
`&r=` / `&p=` (still short for a handful of repos).

> **Full-scope coupling.** Omitting `r=` delegates the repo set to the
> worker's `ALL_REPOS` (ci-dashboard `src/launch.ts`). That list IS the
> "full MCP scope" preset. If the current session's MCP scope differs from it
> (a repo was added/removed), either (a) update `ALL_REPOS` via a ci-dashboard
> PR, or (b) pass an explicit `r=` of the current scope — but a 32-repo `r=`
> makes the link long again, so prefer (a) for the default-scope case.

## Arguments

User input may include:
- **Repositories**: comma-separated `owner/repo` list (optional) → becomes `r=`.
  `all` / `*` / 省略 → default scope (omit `r=`, worker supplies it).
- **Prompt**: free-form text (optional) → becomes `p=`. Omit for the default
  "read the issue" template.
- **Issue / PR ref**: e.g. `ippoan/auth-worker#130` → becomes `i=` (and the
  spec lands there, see below).

## Default repo set — full MCP scope unless the user passes an explicit list

> **Hard rule.** Default = **every repo the current session has GitHub MCP
> scope for** (declared in the system prompt under "Your GitHub MCP tools are
> restricted to the following repositories"). Narrow **only** when the user
> passes an explicit comma-separated `owner/repo` list as the repos argument.

For the default case you don't enumerate the scope into the link — you **omit
`r=`** and the worker attaches its `ALL_REPOS`. Enumerate into `r=` only for an
explicit narrowed list. (Rationale for defaulting wide: cross-repo tasks often
need more repos than the user names — verifying a PR in repo A needs consumer
B + shared hook repo C. Over-attaching is harmless; under-attaching forces a
re-launch.)

### Distinguishing **explicit list** vs **descriptive mention**

| User input | Classification | `r=` |
|---|---|---|
| `ippoan/auth-worker, ippoan/cc-relay — fix bug` | **explicit list** (comma-separated `owner/repo` BEFORE prose) | `r=ippoan/auth-worker,ippoan/cc-relay` |
| `repos=ippoan/auth-worker,ippoan/cc-relay fix bug` | **explicit list** | same |
| `PR #18 が merge された ippoan/claude-md と関連 hook repo (yhonda-ohishi/claude-hooks) …` | **descriptive mention** (repo names inside prose) | **omit** (full scope) |
| `ippoan/cc-relay#37 の続き` | **descriptive mention** (issue ref, not a list) | **omit** |
| `all` / `*` / `全部` / 省略 | **default** | **omit** |

Heuristic: if removing the named repos still leaves a coherent task, they were
descriptive context, not a narrowing constraint. **When in doubt, omit `r=`
(full scope).**

## Spec MUST live on a GitHub issue/PR (mandatory, never skip)

The `/cc` link carries only the issue ref (`i=`). The actual spec lives in that
issue — chat history is ephemeral, the issue is the durable handover artifact,
and `i=` is also what makes the link short.

1. **Identify or create the spec issue/PR FIRST** (non-skippable, even for
   "short" task descriptions):
   - User passed an issue/PR ref → use it as the target. Confirm via
     `mcp__github__issue_read` that the body covers the current task; if stale,
     update via `mcp__github__issue_write` (method: update).
   - No ref → create a new issue via `mcp__github__issue_write` (method:
     create) in the most-relevant repo (infer from the prompt; `AskUserQuestion`
     if truly ambiguous). Title = short task label; body = the actual spec
     (current state, what to do, branch ref, acceptance criteria, related
     PR/issue links).
2. Build the `/cc` link referencing that issue (`i=<owner/repo#N>`).
3. **Embed the link in the issue body** under a `## 起動` (Japanese-default) /
   `## Launch` (English) heading at the top, so a future reader sees it first.
4. Print the link to chat (see "Output").

### Why "short prompt" doesn't exempt issue creation

- **Discoverability**: the launch link otherwise only exists in chat, which
  compacts/expires. The issue is the permanent record.
- **Re-launch**: tasks routinely need a 2nd/3rd launch (CI failed, follow-up).
  With a tracking issue it's a click on the `## 起動` link; without one you
  reconstruct the spec from chat.

When does the spec go in `p=` instead? Almost never. `p=` is for small launch
overrides (a specific non-default branch, a one-phrase out-of-scope note), not
the spec. Multi-paragraph rationale / work breakdowns / acceptance checklists
MUST go in the issue body, never in `p=`.

## Behavior

1. **Resolve `r=`** (repo set):
   - **Explicit list** (comma-separated `owner/repo` as the leading argument,
     not in prose) → validate each `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`, drop
     empties, join with raw commas → `r=<list>`.
   - **Descriptive mention / `all` / 省略 / unsure** → **omit `r=`** (worker
     supplies full scope).
2. **Land the spec on a GitHub issue/PR** (mandatory — see above). This runs
   BEFORE building the link so `i=` can reference the resulting number.
3. **Build the `/cc` link**:
   - Base: `https://ci-dashboard.ippoan.org/cc`
   - `i=` — the issue ref, percent-encoded (`#` → `%23`; the `/` in `owner/repo`
     may stay raw). e.g. `i=ippoan/claude-hooks%238`.
   - `r=` — only if explicit (step 1). Raw commas are fine.
   - `p=` — only for a custom prompt; `encodeURIComponent` it (and encode
     parens, see Implementation notes). Omit for the default template.
4. **Embed the link in the issue body** via `mcp__github__issue_write`
   (method: update), under `## 起動` / `## Launch` at the top:
   ```markdown
   ## 起動

   [🚀 <short label>](<cc-link>)

   ```
   <cc-link>
   ```

   > ci-dashboard `/cc` stateless launch redirect (#214)。
   ```
5. **Output to chat** (see "Output").
6. **Do NOT** post the link anywhere else automatically (Slack, unrelated PR
   comments). Chat + the tracking issue body are the only two places it lives.

## Output

````markdown
### 🚀 [<short label>](<cc-link>)

**Attached repos:** (全 MCP scope)   ← or a bullet list when narrowed via r=
- ...

Spec / handover: <owner>/<repo>#<N>

```
<cc-link>
```
````

- H3 + 🚀 + a **plain Markdown link** (not a badge image — claude.ai chat does
  not auto-load external images and renders shields.io badges as a "show image"
  placeholder, defeating one-click).
- Repo scope line: "全 MCP scope" for the default case, or a bullet list of the
  explicit `r=` repos.
- A 1-line `Spec / handover: <issue>` pointer.
- The bare `/cc` link in a fenced block for copy/paste.

## Examples

### Default scope, NEW issue created

User: `/open-multirepo Phase F acceptance test`

1. Create issue (`mcp__github__issue_write` create) in the inferred repo
   (`ippoan/cc-relay`), body = the Phase F acceptance spec → `ippoan/cc-relay#42`.
2. Link (full scope → no `r`, default prompt → no `p`):
   `https://ci-dashboard.ippoan.org/cc?i=ippoan/cc-relay%2342`
3. Patch #42 body to prepend the `## 起動` block.
4. Chat:

````markdown
### 🚀 [Phase F acceptance test](https://ci-dashboard.ippoan.org/cc?i=ippoan/cc-relay%2342)

**Attached repos:** (全 MCP scope)

Spec / handover: ippoan/cc-relay#42

```
https://ci-dashboard.ippoan.org/cc?i=ippoan/cc-relay%2342
```
````

### Existing issue ref — reuse, don't create new

User: `/open-multirepo ippoan/auth-worker#167 の coverage 100% 復帰`

`issue_read` #167 to confirm the body covers the task (append a section via
`issue_write` update if not). Reuse #167; do not create a new issue. Link:
`https://ci-dashboard.ippoan.org/cc?i=ippoan/auth-worker%23167` (full scope).

### Explicit list — narrowed scope

User: `/open-multirepo ippoan/auth-worker, ippoan/cc-relay — continue auth-worker#130 from the cc-relay broker side`

Repo list leads, comma-separated → narrow via `r=`. Spec lives in
`auth-worker#130`. Link:
`https://ci-dashboard.ippoan.org/cc?i=ippoan/auth-worker%23130&r=ippoan/auth-worker,ippoan/cc-relay`

````markdown
### 🚀 [continue auth-worker#130 (cc-relay broker side)](https://ci-dashboard.ippoan.org/cc?i=ippoan/auth-worker%23130&r=ippoan/auth-worker,ippoan/cc-relay)

**Attached repos:**
- ippoan/auth-worker
- ippoan/cc-relay

Spec / handover: ippoan/auth-worker#130

```
https://ci-dashboard.ippoan.org/cc?i=ippoan/auth-worker%23130&r=ippoan/auth-worker,ippoan/cc-relay
```
````

## Implementation notes

- **Encode `i=` (and `p=`):** `#` → `%23` is the one that bites for `i`. For a
  custom `p=`, `encodeURIComponent` the prompt AND post-process parens, because
  `encodeURIComponent` does NOT touch `!*'()` and an unescaped `)` terminates a
  Markdown `[text](url)` link:
  ```js
  const enc = encodeURIComponent(s)
    .replace(/!/g, '%21').replace(/\*/g, '%2A')
    .replace(/'/g, '%27').replace(/\(/g, '%28').replace(/\)/g, '%29');
  ```
  Verify `/[()]/.test(link) === false` before emitting.
- **`r=` raw commas:** the `/cc` endpoint reads `r` with `URLSearchParams`, so
  raw commas between `owner/repo` entries are fine and keep the link readable.
  Do not enumerate the full scope into `r=` (32 repos ≈ 700 chars → long link);
  omit `r=` and let the worker default.
- If the user gives no prompt and default scope, the link is just `?i=<issue>`.
- If only 1 repo is given explicitly, the skill still works — but note the user
  could just open that repo directly.
- **Keeping the worker's `ALL_REPOS` fresh:** when the MCP scope changes, update
  `ippoan/ci-dashboard` `src/launch.ts` `ALL_REPOS` (PR) so default-scope `/cc`
  links stay correct.
- **Legacy fallback (only if `/cc` is unreachable):** build the full
  `https://claude.ai/code?repositories=<comma list, raw commas>&prompt=<enc>`
  URL directly and shorten via TinyURL
  (`curl -sS "https://tinyurl.com/api-create.php?url=$(node -e 'console.log(encodeURIComponent(process.argv[1]))' -- "$URL")"`),
  disclosing the third-party hop. This is the pre-`/cc` path; use it only when
  the ci-dashboard endpoint is down.
