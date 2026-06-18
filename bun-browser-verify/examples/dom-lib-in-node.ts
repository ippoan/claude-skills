/**
 * 再利用スニペット: ブラウザ前提 (DOMParser / Node / XMLSerializer 等の global を使う) の
 * lib を bun / Node でそのまま動かすための最小 shim。
 *
 * 「アプリの署名・XML 組み立てロジックを bun に移植したいが、lib が `new DOMParser()` や
 * `Node.ELEMENT_NODE` を前提にしていて bun だと ReferenceError」というときの定石。
 * linkedom が browser DOM 互換 API を提供するので、**import より前に** globalThis へ注入する。
 *
 * 依存: `bun add linkedom` (XML/HTML パーサ + Node/Element/XMLSerializer 実装)
 *
 * 重要: **注入は対象 lib を import する前**に行う (top-level `;(globalThis as any)... = ...`)。
 *       lib が module 評価時に global を捕捉するケースがあるため、import 順で効かなくなる。
 */
import { DOMParser, Node, XMLSerializer, parseHTML } from 'linkedom'

// --- ここがキモ: lib が前提にする browser global を bun/Node に生やす ---
;(globalThis as any).DOMParser = DOMParser
;(globalThis as any).Node = Node // Node.ELEMENT_NODE 等の定数アクセス用
;(globalThis as any).XMLSerializer = XMLSerializer
// document が要る lib なら: ;(globalThis as any).document = parseHTML('<!doctype html>').document

// --- 注入後に、ブラウザ前提の lib を import する ---
// 例: e-Gov SDK の XML-DSig (c14n.ts が new DOMParser() / Node.ELEMENT_NODE を使う)
import { parsePfx, signConfig } from '@ippoan/egov-shinsei-sdk/xmldsig'

// PKCS12 / RSA 署名・C14N は node-forge / linkedom 依存なので bun でそのまま動く。
// テスト証明書 (PFX) の値は repo に commit しない (.gitignore 済みの const ファイル等から読む)。
export function signWithTestPfx(configXml: string, refName: string, refBytes: Uint8Array, pfxB64: string, pass: string): string {
  const bin = atob(pfxB64)
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  const parsed = parsePfx(bytes.buffer, pass)
  // linkedom の C14N で作った署名を e-Gov は受理する (署名エラーは出ない)
  return signConfig(configXml, refName, refBytes, parsed)
}
