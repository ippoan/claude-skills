#!/usr/bin/env python3
"""
eml-read — .eml (RFC822) を人間可読テキストに変換する。

ref-files から落とした .eml は MIME で、ヘッダは `=?UTF-8?B?...?=`
(RFC2047)、本文・添付は base64/quoted-printable。Read tool でそのまま開くと
読めないので、ここで decode して stdout に出す。添付は --attach-dir に保存。

Usage:
  python3 eml-read.py <file.eml> [--attach-dir DIR] [--raw-body]
  # PPAP 受領: zip 添付をパスワードで解凍 (パスワードは別メール eml-read で確認)
  python3 eml-read.py <mail1.eml> --attach-dir DIR --unzip-pw 'PASSWORD' --unzip-dir OUT

出力:
  ヘッダ (Subject/From/To/Cc/Date) を decode
  text/plain パートを charset 解決して本文表示 (無ければ text/html を簡易除去)
  添付一覧 (filename は RFC2047 decode)、--attach-dir 指定時は実体を保存
  --unzip-pw 指定時は保存した .zip 添付をパスワードで解凍 (PPAP 受領フロー)
"""
import argparse
import os
import sys
import zipfile
from email import message_from_binary_file
from email.header import decode_header, make_header


def dh(value):
    """RFC2047 ヘッダを decode。失敗時は原文。"""
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def body_text(part):
    """パートのペイロードを charset 解決して str で返す。"""
    payload = part.get_payload(decode=True)
    if payload is None:
        return ""
    charset = part.get_content_charset() or "utf-8"
    for cs in (charset, "utf-8", "cp932", "iso-2022-jp", "latin-1"):
        try:
            return payload.decode(cs)
        except (LookupError, UnicodeDecodeError):
            continue
    return payload.decode("utf-8", errors="replace")


def strip_html(html):
    """text/html しか無い時の最低限のタグ除去 (依存ライブラリ無し)。"""
    import re
    text = re.sub(r"(?is)<(script|style).*?</\1>", "", html)
    text = re.sub(r"(?s)<[^>]+>", "", text)
    text = (text.replace("&nbsp;", " ").replace("&lt;", "<")
                .replace("&gt;", ">").replace("&amp;", "&").replace("&quot;", '"'))
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("eml")
    ap.add_argument("--attach-dir", default=None,
                    help="添付の保存先。指定時のみ実体を書き出す。")
    ap.add_argument("--raw-body", action="store_true",
                    help="text/html しか無くてもタグ除去せず生で出す。")
    ap.add_argument("--unzip-pw", default=None,
                    help="PPAP 受領: 保存した .zip 添付をこのパスワードで解凍する。")
    ap.add_argument("--unzip-dir", default=None,
                    help="解凍先 (省略時は --attach-dir/<zip 名>_extracted)。")
    args = ap.parse_args()
    if args.unzip_pw and not args.attach_dir:
        ap.error("--unzip-pw は --attach-dir と併用してください (zip を保存してから解凍します)")

    with open(args.eml, "rb") as f:
        msg = message_from_binary_file(f)

    print("=" * 60)
    for h in ("Subject", "From", "To", "Cc", "Date"):
        v = msg.get(h)
        if v:
            print(f"{h}: {dh(v)}")
    print("=" * 60)

    plain_parts, html_parts, attachments = [], [], []
    for part in msg.walk():
        if part.get_content_maintype() == "multipart":
            continue
        ctype = part.get_content_type()
        disp = (part.get("Content-Disposition") or "").lower()
        fname = part.get_filename()
        if fname or "attachment" in disp:
            attachments.append((dh(fname) if fname else "(no name)", part))
        elif ctype == "text/plain":
            plain_parts.append(body_text(part))
        elif ctype == "text/html":
            html_parts.append(body_text(part))

    if plain_parts:
        print("\n".join(plain_parts).strip())
    elif html_parts:
        h = "\n".join(html_parts)
        print(h if args.raw_body else strip_html(h))
    else:
        print("(本文テキストパートなし)")

    saved_zips = []
    if attachments:
        print("\n" + "=" * 60)
        print(f"添付 {len(attachments)} 件:")
        for name, part in attachments:
            payload = part.get_payload(decode=True) or b""
            size = len(payload)
            print(f"  - {name}  ({size} B, {part.get_content_type()})")
            if args.attach_dir:
                os.makedirs(args.attach_dir, exist_ok=True)
                safe = os.path.basename(name) or "attachment.bin"
                dest = os.path.join(args.attach_dir, safe)
                with open(dest, "wb") as out:
                    out.write(payload)
                print(f"      saved → {dest}")
                if safe.lower().endswith(".zip"):
                    saved_zips.append(dest)

    # PPAP 受領: 保存した zip をパスワードで解凍
    if args.unzip_pw and saved_zips:
        print("\n" + "=" * 60)
        print("PPAP 解凍:")
        for zpath in saved_zips:
            out_dir = args.unzip_dir or (os.path.splitext(zpath)[0] + "_extracted")
            try:
                with zipfile.ZipFile(zpath) as zf:
                    zf.extractall(path=out_dir, pwd=args.unzip_pw.encode())
                names = os.listdir(out_dir)
                print(f"  {os.path.basename(zpath)} → {out_dir} ({len(names)} entries)")
            except RuntimeError as e:
                # 多くは "Bad password" (ZipCrypto)。AES 暗号化 zip は zipfile 非対応。
                print(f"  {os.path.basename(zpath)}: 解凍失敗 ({e}). "
                      "パスワード誤り、または AES 暗号化 zip (pyzipper が必要) の可能性。")
            except Exception as e:
                print(f"  {os.path.basename(zpath)}: 解凍失敗 ({e})")
    elif args.unzip_pw and not saved_zips:
        print("\n(--unzip-pw 指定だが zip 添付が無い)")


if __name__ == "__main__":
    main()
