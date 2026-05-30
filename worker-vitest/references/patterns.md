# Worker / Frontend Vitest テストパターン集

## 1. REST Proxy Handler

mock/live 統一テストの核心パターン。`stubOrReal()` で fetch の挙動を切り替え、
同じ `it()` が mock (CI 高速) と live (実 API コンテナ) の両方で動く。

### インフラ: `test/helpers/stub-or-real.ts`

```ts
import { vi, beforeAll } from "vitest";
import { isLive, ALC_API_URL, waitForApi, makeJwt } from "./live-env";
import { createMockEnv } from "./mock-env";
import type { Env } from "../../src/index";

const originalFetch = globalThis.fetch;

/** mock: fetch を stub / live: 何もしない (real fetch) */
export function stubOrReal(mockResponse: Response): void {
  if (!isLive) {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValueOnce(mockResponse),
    );
  }
}

/** mock/live で Env を切り替え */
export function testEnv(): Env {
  return createMockEnv(isLive ? { ALC_API_ORIGIN: ALC_API_URL } : {});
}

/** Bearer token 付きリクエスト */
export function authRequest(path: string, init: RequestInit = {}): Request {
  return new Request(`https://auth.test.example${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${makeJwt()}`,
      "Content-Type": "application/json",
      ...init.headers,
    },
  });
}

/** JSON body 付き認証リクエスト */
export function authJsonRequest(
  path: string,
  body: unknown,
  method = "POST",
): Request {
  return authRequest(path, { method, body: JSON.stringify(body) });
}

/** 認証なしリクエスト */
export function noAuthRequest(path: string, method = "POST"): Request {
  return new Request(`https://auth.test.example${path}`, { method });
}

/** 認証なし JSON リクエスト */
export function noAuthJsonRequest(path: string, body: unknown): Request {
  return new Request(`https://auth.test.example${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

/** fetch stub をリストア */
export function restoreFetch(): void {
  vi.stubGlobal("fetch", originalFetch);
}

/** live 時のみ API 起動待ち (beforeAll で使用) */
export function waitIfLive(): void {
  if (isLive) {
    beforeAll(() => waitForApi());
  }
}

/** mock 専用アサーション。live 時はスキップ */
export function assertMock(fn: () => void): void {
  if (!isLive) fn();
}

export { isLive };
```

### テスト例: SSO CRUD

```ts
import { describe, it, expect, beforeEach, afterAll } from "vitest";
import {
  stubOrReal, testEnv, authRequest, authJsonRequest,
  noAuthRequest, restoreFetch, waitIfLive, isLive,
} from "../helpers/stub-or-real";
import { handleSsoList, handleSsoUpsert, handleSsoDelete } from "../../src/handlers/api-sso";

afterAll(() => restoreFetch());
waitIfLive();

describe("handleSsoList", () => {
  const env = testEnv();

  it("returns mapped configs on success", async () => {
    // Setup: upsert a config
    stubOrReal(new Response(JSON.stringify({
      provider: "lineworks", client_id: "cid", external_org_id: "oid",
      enabled: true, woff_id: "wid", created_at: "2025-01-01", updated_at: "2025-01-02",
    }), { status: 200 }));
    await handleSsoUpsert(authJsonRequest("/x", {
      provider: "lineworks", clientId: "cid", clientSecret: "secret",
      externalOrgId: "oid", woffId: "wid", enabled: true,
    }), env);

    // Act: list
    stubOrReal(new Response(JSON.stringify({
      configs: [{
        provider: "lineworks", client_id: "cid", external_org_id: "oid",
        enabled: true, woff_id: "wid", created_at: "2025-01-01", updated_at: "2025-01-02",
      }],
    }), { status: 200 }));
    const res = await handleSsoList(authRequest("/x", { method: "GET" }), env);
    expect(res.status).toBe(200);

    const data = (await res.json()) as { configs: Array<Record<string, unknown>> };
    const c = data.configs.find(x => x.provider === "lineworks")!;

    // Assert: exact values (created_at/updated_at だけ typeof)
    expect(c.provider).toBe("lineworks");
    expect(c.clientId).toBe("cid");
    expect(c.hasClientSecret).toBe(true);
    expect(c.externalOrgId).toBe("oid");
    expect(c.enabled).toBe(true);
    expect(c.woffId).toBe("wid");
    expect(typeof c.createdAt).toBe("string");
    expect(typeof c.updatedAt).toBe("string");

    // Cleanup
    stubOrReal(new Response("ok", { status: 200 }));
    await handleSsoDelete(authJsonRequest("/x", { provider: "lineworks" }), env);
  });
});
```

### ルール

- **1 `it()` = 1 CRUD サイクル**: create → assert → cleanup
- **exact value assert**: mock レスポンスと同じ値を assert。live でも同じ値が返る設計
- **`created_at` / `updated_at`**: DB 生成値なので `typeof "string"` のみ
- **`id`** (UUID): DB 生成の場合は `typeof "string"` 、自分で指定した場合は exact
- **cleanup**: `it()` 内で必ず delete。テスト間の依存を排除

---

## 2. Auth Check

認証チェックのテスト。全ハンドラー共通のパターン。

```ts
it("returns 401 without token", async () => {
  const res = await handleSsoList(noAuthRequest("/x", "GET"), env);
  expect(res.status).toBe(401);
  expect(await res.json()).toEqual({ error: "Unauthorized" });
});

it("returns 401 with non-Bearer auth header", async () => {
  const req = new Request("https://auth.test.example/x", {
    headers: { Authorization: "Basic abc" },
  });
  const res = await handleSsoList(req, env);
  expect(res.status).toBe(401);
});
```

**ポイント**: 認証チェックはハンドラー内で行われるため、`stubOrReal` は不要。
mock/live どちらでも同じ動作。

---

## 3. Validation

必須フィールド欠落のバリデーションテスト。

```ts
it("returns 400 when provider is missing", async () => {
  const res = await handleSsoUpsert(
    authJsonRequest("/x", { clientId: "c", externalOrgId: "o" }),
    env,
  );
  expect(res.status).toBe(400);
});
```

**ポイント**: バリデーションもハンドラー内で行われるため、`stubOrReal` 不要。

---

## 4. Error Passthrough

Backend エラーをそのまま転送するテスト。

```ts
// mock: 任意のエラーを stub
it("passes through error status from backend", async () => {
  stubOrReal(new Response("forbidden", { status: 403 }));

  // live: 無効トークンで実際の 401 を取得
  const req = isLive
    ? new Request("https://auth.test.example/x", {
        method: "GET",
        headers: { Authorization: "Bearer invalid-token" },
      })
    : authRequest("/x", { method: "GET" });

  const res = await handleSsoList(req, testEnv());
  expect(res.status).toBeGreaterThanOrEqual(400);
  const data = (await res.json()) as { error: string };
  expect(typeof data.error).toBe("string");
});
```

### mock/live 分岐が必要な理由

- mock: 任意の HTTP status を stub で返せる
- live: 特定のエラーを意図的に起こすには「無効トークン送信」等の間接手段が必要
- リクエスト構築だけ分岐し、assert は共通にする

---

## 5. Mock-only

Backend が物理的に返せないレスポンスのテスト。

```ts
it("handles undefined configs (fallback to empty)", () => {
  if (isLive) return; // mock-only: real backend always returns { configs: [...] }
  stubOrReal(new Response(JSON.stringify({}), { status: 200 }));
  // ...
});

it("uses fallback error message when backend returns empty text", async () => {
  if (isLive) return; // mock-only: cannot force empty text from backend
  stubOrReal(new Response("", { status: 500 }));
  const res = await handleSsoList(authRequest("/x", { method: "GET" }), env);
  expect(res.status).toBe(500);
  const data = (await res.json()) as { error: string };
  expect(data.error).toBe("Failed to list configs");
});
```

**ポイント**: `if (isLive) return;` で明示的にスキップ。コメントで理由を記載。

---

## 6. Field Mapping

snake_case (backend) → camelCase (frontend) の変換テスト。

```ts
it("maps snake_case to camelCase", async () => {
  stubOrReal(new Response(JSON.stringify({
    client_id: "cid",
    external_org_id: "oid",
    woff_id: null,    // null → "" に変換
    created_at: "2025-01-01",
    updated_at: "2025-01-02",
  }), { status: 200 }));

  const res = await handleSsoList(authRequest("/x", { method: "GET" }), env);
  const data = (await res.json()) as { configs: Array<Record<string, unknown>> };
  const c = data.configs[0]!;

  // camelCase に変換されている
  expect(c.clientId).toBe("cid");
  expect(c.externalOrgId).toBe("oid");
  expect(c.createdAt).toBeDefined();
  expect(c.updatedAt).toBeDefined();

  // null → 空文字変換
  expect(c.woffId).toBe("");

  // 元の snake_case キーは存在しない
  expect(c).not.toHaveProperty("client_id");
  expect(c).not.toHaveProperty("external_org_id");
});
```

---

## 7. Router Test

全ルートの疎通確認。ハンドラーをモックし、ルーティングだけテスト。

```ts
import { vi } from "vitest";

// 全ハンドラーをモック
vi.mock("../../src/handlers/api-sso", () => ({
  handleSsoList: vi.fn(() => new Response("sso-list")),
  handleSsoUpsert: vi.fn(() => new Response("sso-upsert")),
  handleSsoDelete: vi.fn(() => new Response("sso-delete")),
}));

import worker from "../../src/index";

describe("Router", () => {
  const env = createMockEnv();

  const routes: [string, string, string][] = [
    ["GET", "/api/sso/list", "sso-list"],
    ["POST", "/api/sso/upsert", "sso-upsert"],
    ["POST", "/api/sso/delete", "sso-delete"],
  ];

  for (const [method, path, expected] of routes) {
    it(`${method} ${path} → ${expected}`, async () => {
      const req = new Request(`https://auth.test.example${path}`, { method });
      const res = await worker.fetch(req, env);
      expect(await res.text()).toBe(expected);
    });
  }
});
```

**ポイント**: ルーターテストは mock-only。各ハンドラーのロジックは個別テストで検証。

---

## Assert チートシート

| フィールド種別 | assert 方法 | 例 |
|-------------|------------|-----|
| 自分が送った値 | exact match | `expect(c.provider).toBe("lineworks")` |
| boolean | exact match | `expect(c.enabled).toBe(true)` |
| DB 生成 UUID | typeof | `expect(typeof c.id).toBe("string")` |
| DB 生成 timestamp | typeof | `expect(typeof c.createdAt).toBe("string")` |
| null → 空文字変換 | exact match | `expect(c.woffId).toBe("")` |
| 配列の存在 | `Array.isArray` + length | `expect(data.configs.length).toBeGreaterThanOrEqual(1)` |
| エラーメッセージ | mock: exact / live: typeof | パターン [P4](#4-error-passthrough) 参照 |
