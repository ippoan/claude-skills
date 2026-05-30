# Nuxt + Vitest テストパターン集

## 1. Pure Utils

外部依存のない util 関数。直接 import してテスト。

```ts
import { describe, it, expect } from 'vitest'
import { parseLicense } from '~/utils/license'

describe('parseLicense', () => {
  it('有効な免許証番号をパース', () => {
    expect(parseLicense('123456789012')).toEqual({
      prefecture: '12', year: '34', ...
    })
  })

  it('不正な入力は null', () => {
    expect(parseLicense('')).toBeNull()
    expect(parseLicense('short')).toBeNull()
  })
})
```

モジュールスコープに状態がある場合は [P6](#6-module-scope-state-isolation) を併用。

---

## 2. API Mock Composable

API 関数を呼ぶ composable のテスト。`vi.mock` でモジュール全体をモック。

```ts
import { describe, it, expect, vi, beforeEach } from 'vitest'

vi.mock('~/utils/api', () => ({
  getEmployees: vi.fn(),
  saveMeasurement: vi.fn(),
}))

import { useMyComposable } from '~/composables/useMyComposable'
import { getEmployees, saveMeasurement } from '~/utils/api'

describe('useMyComposable', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('従業員一覧を取得', async () => {
    vi.mocked(getEmployees).mockResolvedValueOnce([{ id: '1', name: 'Test' }])
    const { employees, fetchAll } = useMyComposable()
    await fetchAll()
    expect(employees.value).toHaveLength(1)
  })

  it('API エラー時にエラー状態', async () => {
    vi.mocked(getEmployees).mockRejectedValueOnce(new Error('500'))
    const { error, fetchAll } = useMyComposable()
    await fetchAll()
    expect(error.value).toBe('500')
  })
})
```

---

## 3. Browser API Mock

WebSerial, BLE, NFC, MediaDevices 等のブラウザ API。
`Object.defineProperty` でモックし、`delete` でクリーンアップ。

```ts
// WebSerial
Object.defineProperty(navigator, 'serial', {
  value: {
    requestPort: vi.fn().mockResolvedValue(createMockPort()),
    getPorts: vi.fn().mockResolvedValue([]),
  },
  configurable: true,
  writable: true,
})

// BLE
Object.defineProperty(navigator, 'bluetooth', {
  value: {
    requestDevice: vi.fn(),
    getAvailability: vi.fn().mockResolvedValue(true),
  },
  configurable: true,
  writable: true,
})

// MediaDevices
Object.defineProperty(navigator, 'mediaDevices', {
  value: {
    getUserMedia: vi.fn().mockResolvedValue(new MediaStream()),
    enumerateDevices: vi.fn().mockResolvedValue([]),
  },
  configurable: true,
  writable: true,
})

// matchMedia
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  configurable: true,
  value: vi.fn((query: string) => ({
    matches: false,
    media: query,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  })),
})

// クリーンアップ
afterEach(() => {
  delete (navigator as any).serial
  delete (navigator as any).bluetooth
})
```

### SerialPort モック

```ts
function createMockPort(options?: {
  readable?: boolean
  writable?: boolean
  readValues?: Array<{ value: Uint8Array | null; done: boolean }>
}) {
  const readValues = options?.readValues ?? []
  let readIdx = 0

  const mockReader = {
    read: vi.fn(async () => {
      if (readIdx < readValues.length) return readValues[readIdx++]!
      return { value: null, done: true }
    }),
    cancel: vi.fn(async () => {}),
    releaseLock: vi.fn(),
  }

  const mockWriter = {
    write: vi.fn(async () => {}),
    close: vi.fn(async () => {}),
    releaseLock: vi.fn(),
  }

  return {
    open: vi.fn(async () => {}),
    close: vi.fn(async () => {}),
    readable: options?.readable !== false ? { getReader: () => mockReader } : null,
    writable: options?.writable !== false ? { getWriter: () => mockWriter } : null,
    getInfo: vi.fn(() => options?.getInfoResult ?? {}),
    mockReader,
    mockWriter,
  }
}
```

---

## 4. Android Bridge Mock

Android WebView の `window.Android` JS interface をモック。

```ts
beforeEach(() => {
  delete (window as any).Android
})

it('Android bridge あり', () => {
  ;(window as any).Android = {
    getAndroidId: () => 'dev-001',
    isFingerprintAvailable: () => false,
    requestFingerprint: vi.fn(),
    getPhoneNumber: () => '090-1234-5678',
  }

  const result = useMyComposable()
  expect(result.isAndroid.value).toBe(true)
})

it('Android bridge なし (PC)', () => {
  const result = useMyComposable()
  expect(result.isAndroid.value).toBe(false)
})
```

---

## 5. Nuxt Auto-Import Mock

`useRoute`, `useState`, `navigateTo` 等の Nuxt auto-import を `mockNuxtImport` でモック。
**`vi.hoisted()` が必須** — モジュール評価前にモック関数を作成する必要がある。

```ts
import { mockNuxtImport } from '@nuxt/test-utils/runtime'

// vi.hoisted() でモジュール評価前にモック作成
const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {} })),
}))

mockNuxtImport('useRoute', () => useRouteMock)

describe('myComposable', () => {
  it('query パラメータを読む', () => {
    useRouteMock.mockReturnValue({ query: { mode: 'test' } })
    const result = useMyComposable()
    expect(result.mode.value).toBe('test')
  })
})
```

### useState のモック

```ts
const { useStateMock } = vi.hoisted(() => {
  const store = new Map<string, Ref>()
  return {
    useStateMock: vi.fn((key: string, init?: () => any) => {
      if (!store.has(key)) store.set(key, ref(init?.()))
      return store.get(key)!
    }),
  }
})

mockNuxtImport('useState', () => useStateMock)
```

---

## 6. Module-Scope State Isolation

モジュールスコープに `ref()`, `let` 変数を持つシングルトン composable。
テスト間で状態がリークするため、**`vi.resetModules()` + dynamic import** で毎回新しいモジュールを読み込む。

```ts
// composable の型だけ先に取得
let useMyComposable: typeof import('~/composables/useMyComposable').useMyComposable

describe('useMyComposable', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    vi.resetModules()
    const mod = await import('~/composables/useMyComposable')
    useMyComposable = mod.useMyComposable
  })

  it('初期状態', () => {
    const result = useMyComposable()
    expect(result.isConnected.value).toBe(false)
  })

  it('接続後の状態', () => {
    // 前のテストの状態はリセット済み
    const result = useMyComposable()
    result.connect()
    expect(result.isConnected.value).toBe(true)
  })
})
```

**該当パターン**: composable 内に `const isConnected = ref(false)` や `let ws: WebSocket | null = null` がモジュールスコープにある場合。

---

## 7. withSetup Helper

`onMounted` / `onUnmounted` を使う composable は Vue コンポーネントコンテキストが必要。
`withSetup()` ヘルパーで最小の Vue app を作成・マウントする。

```ts
// tests/helpers/with-setup.ts
import { createApp } from 'vue'

export function withSetup<T>(composable: () => T): [T, ReturnType<typeof createApp>] {
  let result!: T
  const app = createApp({
    setup() {
      result = composable()
      return () => {}
    },
  })
  app.mount(document.createElement('div'))
  return [result, app]
}
```

### 使い方

```ts
import { withSetup } from '../helpers/with-setup'

it('onMounted で初期化', () => {
  const [result, app] = withSetup(() => useMyComposable())
  expect(result.isInitialized.value).toBe(true)
  app.unmount()  // onUnmounted が発火
})

it('unmount でクリーンアップ', () => {
  const [result, app] = withSetup(() => useMyComposable())
  app.unmount()
  expect(result.isCleanedUp.value).toBe(true)
})
```

---

## 8. Async Composable (Worker)

Worker の `postMessage` / `onmessage` を使う非同期 composable。

### MockWorker

```ts
let workerInstances: MockWorker[] = []

class MockWorker {
  url: any
  options: any
  onmessage: ((e: MessageEvent) => void) | null = null
  postMessage = vi.fn()
  terminate = vi.fn()

  constructor(url: any, options?: any) {
    this.url = url
    this.options = options
    workerInstances.push(this)
  }

  simulateMessage(data: any) {
    this.onmessage?.(new MessageEvent('message', { data }))
  }
}

vi.stubGlobal('Worker', MockWorker)
vi.stubGlobal('createImageBitmap', vi.fn().mockResolvedValue({ close: vi.fn() }))
```

### async テストの await tick パターン

`await createImageBitmap()` 後に `worker.postMessage` が呼ばれる場合、テスト側で **tick を挟む**:

```ts
it('detect で Worker にメッセージ送信', async () => {
  const fd = useFaceDetection()
  // load 完了
  const loadPromise = fd.load()
  workerInstances[0]!.simulateMessage({ type: 'ready' })
  await loadPromise

  // detect 開始
  const detectPromise = fd.detect(mockVideo)
  await new Promise(r => setTimeout(r, 0))  // createImageBitmap の await を通す

  const w = workerInstances[0]!
  expect(w.postMessage).toHaveBeenLastCalledWith(
    expect.objectContaining({ type: 'detect-lite' }),
    expect.any(Array)
  )

  // Worker から結果を返す
  w.simulateMessage({ type: 'result-lite', face: [], gesture: {} })
  await detectPromise
})
```

---

## 9. MockWebSocket

WebSocket を使う composable のテスト。`simulate*` ヘルパーで接続・メッセージ・切断をシミュレート。

```ts
type WsHandler = ((ev: any) => void) | null

class MockWebSocket {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSING = 2
  static CLOSED = 3
  static instances: MockWebSocket[] = []

  readyState = MockWebSocket.CONNECTING
  url: string
  onopen: WsHandler = null
  onmessage: WsHandler = null
  onclose: WsHandler = null
  onerror: WsHandler = null
  sent: string[] = []

  constructor(url: string) {
    this.url = url
    MockWebSocket.instances.push(this)
  }

  send(data: string) { this.sent.push(data) }

  close() {
    this.readyState = MockWebSocket.CLOSED
    if (this.onclose) this.onclose({})  // 同期的に発火!
  }

  simulateOpen() {
    this.readyState = MockWebSocket.OPEN
    if (this.onopen) this.onopen({})
  }

  simulateMessage(data: any) {
    if (this.onmessage) this.onmessage({ data: JSON.stringify(data) })
  }

  simulateError() {
    if (this.onerror) this.onerror({})
  }

  simulateClose() {
    this.readyState = MockWebSocket.CLOSED
    if (this.onclose) this.onclose({})
  }
}

vi.stubGlobal('WebSocket', MockWebSocket)

beforeEach(() => { MockWebSocket.instances = [] })
```

### 重要: `close()` は同期的に `onclose` を発火する

`onclose` 内で `transport.value = null` が設定されるため、`ws.close()` **後**に状態チェックすると意図しない結果になる。**チェックは `close()` 前に行う**。

---

## 10. Fake Timers

リトライ・ポーリング・自動再接続のテスト。

```ts
beforeEach(() => {
  // 必ず toFake で必要なタイマーだけ指定
  vi.useFakeTimers({
    toFake: ['setTimeout', 'setInterval', 'clearTimeout', 'clearInterval'],
  })
})

afterEach(() => {
  vi.useRealTimers()  // 必須!
})

it('5秒後にリトライ', async () => {
  const result = useMyComposable()
  result.connect()
  // 接続失敗をシミュレート
  MockWebSocket.instances[0]!.simulateError()

  // タイマーを進める
  await vi.advanceTimersByTimeAsync(5000)

  // リトライで新しい WebSocket が作成される
  expect(MockWebSocket.instances).toHaveLength(2)
})
```

### 注意

- **bare `vi.useFakeTimers()` は禁止** — happy-dom が `navigator`, `WebSocket` と干渉する
- async 関数 + fake timers はタイムアウトしやすい → `advanceTimersByTimeAsync` を使用
- `afterEach` で `vi.useRealTimers()` を忘れると後続テストが壊れる

---

## 11. API Dual-Mode

1つのテストコードで mock (高速) と live (実 API コンテナ) の両方で動く設計。

### インフラファイル

- `tests/helpers/api-test-env.ts` — `isLive` フラグ、`mockFetch`、`stubOk()`, `stub204()`, `verifyApi()`, `callApi()`, `expectMock()`, `setupApi()`, `teardownApi()`
- `tests/helpers/api-test-data.ts` — 共有 ID (`TEST_TENANT_ID`, `SEED_*`)、リクエストボディ
- `tests/fixtures/seed.sql` — live DB 用シードデータ

### パターン

```ts
import {
  setupApi, teardownApi, stubOk, stub204,
  assertMock, expectMock, mockFetch,
} from '../helpers/api-test-env'

beforeEach(async () => { await setupApi() })
afterEach(() => { teardownApi() })

it('一覧取得', async () => {
  stubOk([{ id: '1', name: 'Test' }])  // live 時は no-op
  const result = await getItems()
  assertMock(() => {  // live 時はスキップ
    expect(mockFetch).toHaveBeenCalledWith(
      expect.stringContaining('/api/items'),
      expect.any(Object)
    )
  })
})
```

### 実行

```bash
npm test                                          # mock モード
docker compose -f docker-compose.test.yml up -d   # API + DB 起動
API_BASE_URL=http://localhost:18080 npm test       # live モード
docker compose -f docker-compose.test.yml down -v  # 停止
```

### ルール

- テストデータ ID は有効な UUID (`api-test-data.ts` から import)。`'s1'`, `'e1'` は禁止
- リクエストボディは実 API が受け付ける正しいフィールド名 (`api-test-data.ts` から import)
- テストファイルを mock 用 / live 用に分けない。1ファイルで完結

---

## 12. SSR Guard

`if (import.meta.client)` ガードは happy-dom テスト環境では常に `true` になり、`else` ブランチがカバーされない。

### 対策

1. **onMounted に移動** — `onMounted` 自体が SSR で実行されないため、ガード不要:
   ```ts
   // Before (カバレッジ問題)
   if (import.meta.client) {
     window.addEventListener('resize', handler)
   }

   // After
   onMounted(() => {
     window.addEventListener('resize', handler)
   })
   ```

2. **ガード削除** — composable が client-only の場合、ガードを完全に削除

---

## 13. Unreachable Branch

v8 coverage が未カバーとして報告するが、実際には到達不可能なブランチ。

### パターンと対策

| 到達不能コード | 対策 |
|--------------|------|
| `if (!db.objectStoreNames.contains('store'))` (初回のみ) | 条件を消して常に実行 |
| `default` in exhaustive switch | `satisfies never` パターン |
| `catch` after infallible operation | 削除 or `try` 自体を除去 |
| `else` after early return | early return の条件を反転 |

```ts
// Before (到達不能 else)
if (condition) {
  doSomething()
} else {
  // ここには来ない
}

// After
doSomething()
```

```ts
// exhaustive switch with never check
switch (type) {
  case 'a': return handleA()
  case 'b': return handleB()
  default: {
    const _: never = type  // コンパイル時に網羅性保証
    throw new Error(`Unknown type: ${type}`)
  }
}
```

---

## 14. Vue コンポーネント v8 ブランチカバレッジ

Vue SFC の `<template>` はレンダー関数にコンパイルされ、`:class` 三項演算子や `v-if`/`v-else` が
JS ブランチとして v8 に追跡される。Vue の内部最適化パス（差分検出スキップ等）により、
テストで両方のパスを通しても v8 が未カバーと報告するケースがある。

### 対策: テンプレートブランチを子コンポーネントに抽出

**問題:** 親コンポーネントに複数の `v-if`/`v-else` や `:class` 三項演算子があると、
Vue コンパイラの最適化ブランチが蓄積し Branch 100% に到達不可能。

**解決:** ブランチを含むテンプレート部分を小さな子コンポーネントに抽出する。
各子コンポーネントのレンダー関数が単純になり、v8 が全ブランチを追跡可能になる。

```
Before (Branch 84%):
  EventDataTable.vue  ← v-if/v-else + :class ternary が集中

After (Branch 100%):
  EventDataTable.vue      ← タブ切り替えのみ
  ├── EventCrewPanel.vue  ← フィルタ + テーブル
  │   └── EventTableCell.vue  ← location / regular の振り分け
  │       ├── EventLocationCell.vue  ← GPS ボタン or プレーンテキスト
  │       └── EventCell.vue          ← フォーマット済みテキスト + 色
```

**原則:**
- 1つの `.vue` ファイルに `v-if`/`v-else` は1箇所まで
- `:class` 三項演算子は子コンポーネントの computed に移動
- ロジック（純粋関数）は `app/utils/` に抽出し、コンポーネントは描画に集中
- `/* v8 ignore */` は禁止 — カバレッジの意味がなくなる
- `coverage_100.toml` で Vue テンプレートブランチが残る場合は `branches = false`（lines のみ）で登録

**テスト:**
```ts
import { mount } from '@vue/test-utils'
import EventLocationCell from '~/components/EventLocationCell.vue'

// UIcon 等の Nuxt コンポーネントはスタブ化
const UIconStub = { template: '<span />' }  // tests/helpers/stubs.ts に共通化

const wrapper = mount(EventLocationCell, {
  props: { headers, row, header: '開始市町村名', value: '東京都' },
  global: { stubs: { UIcon: UIconStub } },
})
```

**`??` フォールバックブランチ:** `row[col.index] ?? ''` の右辺を通すには、
行データが列数より短いテストケースを追加する。
