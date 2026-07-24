#!/usr/bin/env node
/**
 * wrangler dev の hot reload 反映検知 (dev-login-local-verify skill 付属)。
 *
 * 原理: `nuxt build` が `.output/server/chunks/_/nitro.mjs` に埋める buildId
 * (build ごとのランダム UUID) と、http://localhost:<port>/login が実際に配信
 * している HTML 内の buildId を比較する。一致した瞬間 = wrangler の自動
 * 再バンドル+再アップロードが完了し新ビルドが配信され始めた時刻 (ground truth)。
 *
 * 使い方:
 *   node reload-watch.mjs <worktreeDir> [port]      # CLI: 反映まで待って報告
 *   node reload-watch.mjs --hook                    # Claude Code PostToolUse hook
 *
 * hook モードは stdin の JSON (tool_input.command) を読み、`nuxt build` を含む
 * Bash コマンドの時だけ動く。`cd "<dir>" && ...` から worktree を推定し、
 * :8787 が応答しなければ黙って exit 0 (wrangler dev 未起動 = 監視対象なし)。
 */
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const TIMEOUT_MS = 90_000
const POLL_MS = 2_000
const BUILD_ID_RE = /buildId[":\s]*"([a-f0-9-]{36})"/

function expectedBuildId(worktreeDir) {
  const nitro = readFileSync(join(worktreeDir, '.output/server/chunks/_/nitro.mjs'), 'utf8')
  const m = BUILD_ID_RE.exec(nitro)
  if (!m) throw new Error('.output の nitro.mjs に buildId が見つからない')
  return m[1]
}

async function servedBuildId(port) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), 5_000)
  try {
    const res = await fetch(`http://localhost:${port}/login`, { signal: ctl.signal })
    const html = await res.text()
    return BUILD_ID_RE.exec(html)?.[1] ?? null
  } catch {
    return null
  } finally {
    clearTimeout(timer)
  }
}

/** @returns {Promise<string>} 人間可読の結果1行 */
async function waitForReload(worktreeDir, port) {
  const expected = expectedBuildId(worktreeDir)
  const t0 = Date.now()
  while (Date.now() - t0 < TIMEOUT_MS) {
    const served = await servedBuildId(port)
    if (served === expected) {
      const ts = new Date().toLocaleTimeString('ja-JP')
      const sec = Math.round((Date.now() - t0) / 1000)
      return `wrangler reload 反映済み ${ts} (+${sec}s, buildId=${expected.slice(0, 8)})`
    }
    if (served === null && Date.now() - t0 > 10_000) {
      return `:${port} が応答しない — wrangler dev が起動しているか確認`
    }
    await new Promise((r) => setTimeout(r, POLL_MS))
  }
  return `TIMEOUT ${TIMEOUT_MS / 1000}s: 配信中 buildId が .output と一致しない (wrangler の watch が発火していない可能性)`
}

async function main() {
  const args = process.argv.slice(2)

  if (args[0] === '--hook') {
    let input = ''
    for await (const chunk of process.stdin) input += chunk
    let command = ''
    try {
      command = JSON.parse(input)?.tool_input?.command ?? ''
    } catch {
      process.exit(0)
    }
    if (!/nuxt build/.test(command)) process.exit(0)
    const dirMatch = /cd\s+"([^"]+)"/.exec(command)
    if (!dirMatch) process.exit(0)
    const worktreeDir = dirMatch[1]
    if ((await servedBuildId(8787)) === null) process.exit(0) // wrangler dev 不在
    const result = await waitForReload(worktreeDir, 8787)
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: result },
      }),
    )
    process.exit(0)
  }

  const worktreeDir = args[0]
  const port = Number(args[1] ?? 8787)
  if (!worktreeDir) {
    console.error('usage: node reload-watch.mjs <worktreeDir> [port] | --hook')
    process.exit(2)
  }
  console.log(await waitForReload(worktreeDir, port))
}

await main()
