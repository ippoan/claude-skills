/**
 * submitOne (final-test.vue) の個別署名分岐を Trial 用に移植したビルダー。
 * 署名は付けない (Trial)。apply XML は skeleton のまま (e-Gov Trial は全エラーを返すため
 * 構成レベルの「様式ID 登録なし」は apply 未充填でも surface する想定)。
 *
 * 入力:  skeleton.json = e-Gov /procedure/{id} の results ({file_data, configuration_file_name, file_info})
 * 出力:  built.b64 = Trial 送信用 zip の base64
 */
import { DOMParser, Node } from 'linkedom'
// SDK の c14n.ts はブラウザの global DOMParser / Node を使う。bun には無いので linkedom を注入
;(globalThis as any).DOMParser = DOMParser
;(globalThis as any).Node = Node
import JSZip from 'jszip'
import { readFileSync, writeFileSync } from 'node:fs'
import { PROCS_WITH_DESTINATION, PROCS_WITH_PAYMENT, PROCS_WITH_ATTACHMENT, TEST_PROCEDURES } from '<path-to>/nuxt-egov/app/utils/finalTestProcedures'
import { parsePfx, signConfig } from '@ippoan/egov-shinsei-sdk/xmldsig'
// GPKI テスト証明書 (gpkitest) は nuxt-egov app/composables/useXmlSign.ts の TEST_PFX_BASE64 から取得し
// pfx-const.ts (export const TEST_PFX_BASE64 = '...') として置く。証明書値はこの repo に commit しない。
import { TEST_PFX_BASE64 } from './pfx-const.ts'

// テスト証明書 (gpkitest) を parse — submitOne と同じ署名を Trial 用に bun 上で付与する
const pfxBin = atob(TEST_PFX_BASE64)
const pfxBytes = new Uint8Array(pfxBin.length)
for (let i = 0; i < pfxBin.length; i++) pfxBytes[i] = pfxBin.charCodeAt(i)
const parsedPfx = parsePfx(pfxBytes.buffer, 'gpkitest')

const PROC_ID = process.argv[2] || '950A102200038000'
const proc = TEST_PROCEDURES.find(p => p.proc_id === PROC_ID)!
if (!proc) throw new Error('proc not found: ' + PROC_ID)

const TEST_PDF_BASE64 = 'JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyAyIDAgUj4+ZW5kb2JqIDIgMCBvYmo8PC9UeXBlL1BhZ2VzL0tpZHNbMyAwIFJdL0NvdW50IDE+PmVuZG9iaiAzIDAgb2JqPDwvVHlwZS9QYWdlL1BhcmVudCAyIDAgUi9NZWRpYUJveFswIDAgNjEyIDc5Ml0+PmVuZG9iagp4cmVmCjAgNAowMDAwMDAwMDAwIDY1NTM1IGYKMDAwMDAwMDAxMCAwMDAwMCBuCjAwMDAwMDAwNTMgMDAwMDAgbgowMDAwMDAwMDk0IDAwMDAwIG4KdHJhaWxlcjw8L1NpemUgNC9Sb290IDEgMCBSPj4Kc3RhcnR4cmVmCjE0OQolJUVPRgo='
function testPdfBytes(): Uint8Array {
  const bin = atob(TEST_PDF_BASE64)
  const arr = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i)
  return arr
}
const APPLICANT_PERSONAL_TAGS = ['氏名フリガナ', '氏名', '郵便番号', '住所フリガナ', '住所', '電話番号', '電子メールアドレス', '法人名']
function emptyApplicantTags(xml: string): string {
  for (const tag of APPLICANT_PERSONAL_TAGS) {
    xml = xml.replace(new RegExp(`<${tag}>[^<]*</${tag}>`, 'g'), `<${tag}/>`)
  }
  return xml
}

const testData = {
  氏名: 'テスト　太郎', 氏名フリガナ: 'テスト　タロウ', 郵便番号: '1000014',
  住所: '東京都千代田区永田町１丁目７番１号', 住所フリガナ: 'トウキョウトチヨダクナガタチョウ',
  電話番号: '03-1234-5678', 電子メールアドレス: 'test@example.com', 法人名: 'テスト株式会社',
}

const skeleton = { results: JSON.parse(readFileSync(new URL('./skeleton.json', import.meta.url), 'utf8')) }
const zipData = Uint8Array.from(atob(skeleton.results.file_data), (c: string) => c.charCodeAt(0))
const zip = await JSZip.loadAsync(zipData)

const kouseiTestValues: Record<string, string> = {
  受付行政機関ID: '100' + proc.proc_id.substring(0, 3),
  手続ID: proc.proc_id, 手続名称: proc.name, 申請種別: '新規申請',
  氏名: testData.氏名, 氏名フリガナ: testData.氏名フリガナ, 郵便番号: testData.郵便番号,
  住所: testData.住所, 住所フリガナ: testData.住所フリガナ, 電話番号: testData.電話番号,
  電子メールアドレス: testData.電子メールアドレス, 法人名: testData.法人名,
}
if (PROCS_WITH_DESTINATION.has(proc.proc_id)) {
  kouseiTestValues['提出先識別子'] = proc.proc_id.startsWith('950A') ? '950API00000000001001001' : '900API00000000001001001'
  kouseiTestValues['提出先名称'] = '総務省,行政管理局,API'
}

const configFiles: string[] = skeleton.results.configuration_file_name
const fileInfos: Array<{ form_id: string; form_version: number; form_name: string; apply_file_name: string }> = skeleton.results.file_info

let signAttachName: string | null = null
const writeAppliNames: string[] = []
const mainConfigName = configFiles[0]!
for (let idx = 1; idx < configFiles.length; idx++) {
  const cfName = configFiles[idx]!
  const cf = zip.file(`${proc.proc_id}/${cfName}`)
  if (!cf) continue
  const cx = await cf.async('string')
  const yoshikiId = cx.match(/<様式ID>([^<]*)<\/様式ID>/)?.[1]
  if (yoshikiId === '999000000000000001') signAttachName = cfName
  else writeAppliNames.push(cfName)
}
const requiredAttachments = PROCS_WITH_ATTACHMENT.get(proc.proc_id) ?? []
const baseProcId = proc.proc_id.slice(0, -3)
const writeAppliProcId = `${baseProcId}F01`
const signAttachProcId = `${baseProcId}T01`

console.error('[diag] writeAppliNames=', writeAppliNames, 'signAttach=', signAttachName)
console.error('[diag] file_info=', fileInfos.map(f => ({ id: f.form_id, ver: f.form_version, apply: f.apply_file_name })))

// --- main kousei.xml ---
const mainPath = `${proc.proc_id}/${mainConfigName}`
const mainFile = zip.file(mainPath)
if (mainFile) {
  let xml = await mainFile.async('string')
  for (const [tag, value] of Object.entries(kouseiTestValues)) {
    xml = xml.replace(new RegExp(`<${tag}/>`, 'g'), `<${tag}>${value}</${tag}>`)
    xml = xml.replace(new RegExp(`<${tag}></${tag}>`, 'g'), `<${tag}>${value}</${tag}>`)
  }
  if (PROCS_WITH_PAYMENT.has(proc.proc_id) && !xml.includes('<納付関連情報>')) {
    xml = xml.replace('<法人番号>', '<納付関連情報><納付方法>1</納付方法><振込者氏名カナ>テストタロウ</振込者氏名カナ></納付関連情報>\n\t\t\t\t\t<法人番号>')
  }
  let attachBlocks = ''
  for (let i = 0; i < fileInfos.length; i++) {
    const fi = fileInfos[i]; const waName = writeAppliNames[i]
    if (!fi || !waName) continue
    attachBlocks += `<添付書類属性情報><添付種別>添付</添付種別><添付書類名称>${fi.form_name}の構成情報</添付書類名称><添付書類ファイル名称>${waName}</添付書類ファイル名称><提出情報>1</提出情報></添付書類属性情報>`
    attachBlocks += `<添付書類属性情報><添付種別>添付</添付種別><添付書類名称>${fi.form_name}</添付書類名称><添付書類ファイル名称>${fi.apply_file_name}</添付書類ファイル名称><提出情報>1</提出情報></添付書類属性情報>`
  }
  if (signAttachName) {
    attachBlocks += `<添付書類属性情報><添付種別>添付</添付種別><添付書類名称>添付書類署名ファイル１の構成情報</添付書類名称><添付書類ファイル名称>${signAttachName}</添付書類ファイル名称><提出情報>1</提出情報></添付書類属性情報>`
    attachBlocks += `<添付書類属性情報><添付種別>添付</添付種別><添付書類名称>添付書類署名ファイル１</添付書類名称><添付書類ファイル名称>Test.pdf</添付書類ファイル名称><提出情報>1</提出情報></添付書類属性情報>`
  }
  for (const attName of requiredAttachments) {
    const attFile = `${attName}.txt`
    attachBlocks += `<添付書類属性情報><添付種別>添付</添付種別><添付書類名称>${attName}</添付書類名称><添付書類ファイル名称>${attFile}</添付書類ファイル名称><提出情報>1</提出情報></添付書類属性情報>`
    zip.file(`${proc.proc_id}/${attFile}`, 'test')
  }
  xml = xml.replace('</管理情報>', '</管理情報>' + attachBlocks)
  xml = xml.replace(/<申請書属性情報>[\s\S]*?<\/申請書属性情報>/g, '')
  xml = xml.replace(/<申請書属性情報\s*\/>/g, '')
  zip.file(mainPath, xml)
}

// --- SignAttach ---
if (signAttachName) {
  const signAttachPath = `${proc.proc_id}/${signAttachName}`
  const signAttachFile = zip.file(signAttachPath)
  if (signAttachFile) {
    let xml = await signAttachFile.async('string')
    const v: Record<string, string> = { 受付行政機関ID: '100' + proc.proc_id.substring(0, 3), 手続ID: signAttachProcId, 手続名称: proc.name, 申請種別: '添付書類署名' }
    for (const [tag, value] of Object.entries(v)) {
      xml = xml.replace(new RegExp(`<${tag}/>`, 'g'), `<${tag}>${value}</${tag}>`)
      xml = xml.replace(new RegExp(`<${tag}></${tag}>`, 'g'), `<${tag}>${value}</${tag}>`)
    }
    xml = emptyApplicantTags(xml)
    if (!xml.includes('<添付書類属性情報>')) {
      xml = xml.replace('</管理情報>', '</管理情報>' + `<添付書類属性情報><添付種別>添付</添付種別><添付書類名称>添付書類署名ファイル１</添付書類名称><添付書類ファイル名称>Test.pdf</添付書類ファイル名称><提出情報>1</提出情報></添付書類属性情報>`)
    }
    xml = xml.replace(/<申請書属性情報>[\s\S]*?<\/申請書属性情報>/g, '')
    xml = xml.replace(/<申請書属性情報\s*\/>/g, '')
    zip.file(signAttachPath, xml)
  }
}

// --- WriteAppli × N (writeAppliNames[i] ↔ fileInfos[i]) ---
for (let i = 0; i < writeAppliNames.length; i++) {
  const waName = writeAppliNames[i]!
  const fi = fileInfos[i]
  const writeAppliPath = `${proc.proc_id}/${waName}`
  const writeAppliFile = zip.file(writeAppliPath)
  if (!writeAppliFile) continue
  let xml = await writeAppliFile.async('string')
  const v: Record<string, string> = { 受付行政機関ID: '100' + proc.proc_id.substring(0, 3), 手続ID: writeAppliProcId, 手続名称: proc.name, 申請種別: '申請書作成' }
  for (const [tag, value] of Object.entries(v)) {
    xml = xml.replace(new RegExp(`<${tag}/>`, 'g'), `<${tag}>${value}</${tag}>`)
    xml = xml.replace(new RegExp(`<${tag}></${tag}>`, 'g'), `<${tag}>${value}</${tag}>`)
  }
  xml = emptyApplicantTags(xml)
  xml = xml.replace(/<添付書類属性情報>[\s\S]*?<\/添付書類属性情報>/g, '')
  xml = xml.replace(/<添付書類属性情報\s*\/>/g, '')
  if (!xml.includes('<申請書属性情報>') && fi) {
    // 総当たり用: FORCE_VER_<i> / FORCE_ID_<i> で fileInfos[i] の様式バージョン/ID を上書き
    const forcedVer = process.env[`FORCE_VER_${i}`]
    const forcedId = process.env[`FORCE_ID_${i}`]
    const ver = forcedVer ?? String(fi.form_version).padStart(4, '0')
    const fid = forcedId ?? fi.form_id
    if (forcedVer || forcedId) {
      // apply XML 側の <様式ID>/<様式バージョン> も合わせて書き換え (署名前なので digest 再計算される)
      const ap = `${proc.proc_id}/${fi.apply_file_name}`
      const af = zip.file(ap)
      if (af) {
        let ax = await af.async('string')
        if (forcedVer) ax = ax.replace(/<様式バージョン>[^<]*<\/様式バージョン>/, `<様式バージョン>${ver}</様式バージョン>`)
        if (forcedId) ax = ax.replace(/<様式ID>[^<]*<\/様式ID>/, `<様式ID>${fid}</様式ID>`)
        zip.file(ap, ax)
      }
    }
    const fname = process.env[`FORCE_NAME_${i}`] ?? fi.form_name
    const block = `<申請書属性情報><申請書様式ID>${fid}</申請書様式ID><申請書様式バージョン>${ver}</申請書様式バージョン><申請書様式名称>${fname}</申請書様式名称><申請書ファイル名称>${fi.apply_file_name}</申請書ファイル名称></申請書属性情報>`
    xml = xml.replace('</構成情報>', block + '</構成情報>')
    console.error(`[diag] WriteAppli[${i}] (${waName}) 申請書属性情報: id=${fid} ver=${ver} apply=${fi.apply_file_name}`)
  }
  zip.file(writeAppliPath, xml)
}
zip.file(`${proc.proc_id}/Test.pdf`, testPdfBytes(), { binary: true })

// --- 署名 (submitOne の個別署名分岐と同じ。main kousei.xml は署名しない) ---
// SignAttach: Test.pdf を参照して署名
if (signAttachName) {
  const saPath = `${proc.proc_id}/${signAttachName}`
  const saFile = zip.file(saPath)
  if (saFile) {
    const saXml = await saFile.async('string')
    const pdf = await zip.file(`${proc.proc_id}/Test.pdf`)!.async('uint8array')
    zip.file(saPath, signConfig(saXml, 'Test.pdf', pdf, parsedPfx))
  }
}
// WriteAppli × N: 各 apply ファイルを参照して署名 (writeAppliNames[i] ↔ fileInfos[i])
for (let i = 0; i < writeAppliNames.length; i++) {
  const waName = writeAppliNames[i]!
  const fi = fileInfos[i]
  if (!fi) continue
  const waPath = `${proc.proc_id}/${waName}`
  const waFile = zip.file(waPath)
  const applyFile = zip.file(`${proc.proc_id}/${fi.apply_file_name}`)
  if (!waFile || !applyFile) continue
  const waXml = await waFile.async('string')
  const applyContent = await applyFile.async('string')
  zip.file(waPath, signConfig(waXml, fi.apply_file_name, applyContent, parsedPfx))
}
console.error('[diag] signed: SignAttach + WriteAppli×' + writeAppliNames.length)

// apply XML は skeleton のまま (Trial: 全エラー列挙されるので構成レベルの様式IDエラーは surface する)
const b64 = await zip.generateAsync({ type: 'base64' })
writeFileSync(new URL('./built.b64', import.meta.url), b64)
console.error('[diag] built zip base64 length=', b64.length)
