#!/usr/bin/env python3
"""`--body-file` が指す本文を、**同じコマンド文字列の文脈**から解決する。

2 本の hook (PreToolUse / PermissionDenied) が **どちらもこのモジュールを import する**。
本文を読めたか否かは PreToolUse の deny/pass を分けるので、解決の強さが 2 か所で
食い違うと、片方の hook だけ誤爆する。

## なぜ素の `open()` では足りないか (#157 で実際に 2 回誤爆した)

1. **変数がまだ展開されていない**

       SP=/tmp/…/<セッション UUID>/scratchpad
       gh … --body-file "$SP/pr.md"

   `$SP` は shell が展開するもので、hook の手元には literal のまま届く。

2. **PreToolUse は実行「前」なので、本文ファイルがまだ無い**

       cp <scratchpad>/pr.md /tmp/pr-body.md && gh … --body-file /tmp/pr-body.md

   走査の時点で `/tmp/pr-body.md` は存在しない。

どちらも「読めなかった」で終わるとコマンド全文へのフォールバックしか残らず、
**作業パスに紛れ込んだ UUID** で止まる。本番識別子ではないものを止めた検査は外される。
だから止め方を緩めるのではなく、**本文を読む力を上げる**のがここの役目。
"""

from __future__ import annotations

import os
import re
import shlex

# shlex は演算子も 1 トークンとして返す。ここで次のコマンドとの境目を切る。
COMMAND_SEPARATORS = {"&&", "||", ";", "|", "&", "\n"}

# `cat src > dst` の検出用。stderr のリダイレクト (`2>`) は本文を作らないので見ない。
REDIRECT_RE = re.compile(r"\A(1?>>?)(\S*)\Z")

# 本文ファイルを「直前に作る」コマンド。最後の引数が生成先。
COPY_COMMANDS = {"cp", "mv", "install"}

# `VAR=値` / `VAR="値"` / `VAR='値'`。`--repo=x` を拾わないよう、
# 直前が行頭か空白・区切りのときだけ変数名とみなす。
ASSIGNMENT_RE = re.compile(
    r"""(?:\A|(?<=[\s;&|(]))([A-Za-z_][A-Za-z0-9_]*)="""
    r"""(?:"([^"]*)"|'([^']*)'|([^\s;&|<>]*))"""
)

VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")

# 変数の入れ子展開と、生成元をたどる深さの上限。循環しても止まるための数字。
MAX_HOPS = 3


def tokenize(command: str) -> list[str]:
    """引用が壊れていても何かは返す。壊れているかは呼び手が別途知る必要がある。"""
    try:
        return shlex.split(command, comments=False)
    except ValueError:
        return command.split()


def split_commands(tokens: list[str]) -> list[list[str]]:
    """`&&` などで区切って、コマンドごとのトークン列にする。"""
    commands: list[list[str]] = [[]]
    for token in tokens:
        if token in COMMAND_SEPARATORS:
            commands.append([])
        else:
            commands[-1].append(token)
    return [c for c in commands if c]


def _collect_assignments(command: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for m in ASSIGNMENT_RE.finditer(command):
        name = m.group(1)
        if m.group(2) is not None:
            value = m.group(2)
        elif m.group(3) is not None:
            value = m.group(3)
        else:
            value = m.group(4) or ""
        values[name] = value
    return values


def _split_redirect(tokens: list[str]) -> tuple[list[str], str | None]:
    """`… > dst` を (リダイレクト前のトークン列, dst) に割る。無ければ (元のまま, None)。"""
    for i, token in enumerate(tokens):
        m = REDIRECT_RE.match(token)
        if not m:
            continue
        dst = m.group(2)
        if not dst:
            dst = tokens[i + 1] if i + 1 < len(tokens) else None
        return tokens[:i], dst
    return tokens, None


def _collect_producers(tokens: list[str]) -> list[tuple[str, list[str]]]:
    """同じコマンド内で「ファイルを作る」呼び出しを (生成先, 生成元たち) で拾う。"""
    producers: list[tuple[str, list[str]]] = []
    for command in split_commands(tokens):
        head, dst = _split_redirect(command)
        if dst:
            # `cat a b > dst` のときだけ生成元が分かる。他のコマンドの出力は追えない。
            if head and os.path.basename(head[0]) == "cat":
                srcs = [t for t in head[1:] if not t.startswith("-")]
                if srcs:
                    producers.append((dst, srcs))
            continue
        if os.path.basename(command[0]) not in COPY_COMMANDS:
            continue
        operands = [t for t in command[1:] if not t.startswith("-")]
        if len(operands) >= 2:
            producers.append((operands[-1], operands[:-1]))
    return producers


def _normalize(path: str) -> str:
    return os.path.normpath(os.path.expanduser(path)) if path else ""


def _read_file(path: str) -> str | None:
    if not path or path == "-":
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


class BodyFileResolver:
    """1 つの Bash コマンド文字列を文脈として、`--body-file` の中身を読む。

    読めれば本文、最後まで読めなければ `None`。**`None` を「安全」と読まないこと**
    (呼び手は fail-closed で止める)。
    """

    def __init__(self, command: str) -> None:
        self.command = command or ""
        self.tokens = tokenize(self.command)
        self.assignments = _collect_assignments(self.command)
        self.producers = _collect_producers(self.tokens)

    def expand(self, path: str) -> str:
        """コマンド内の `VAR=…` を使って `$VAR` / `${VAR}` を埋める。"""
        text = path or ""
        for _ in range(MAX_HOPS):
            filled = VAR_RE.sub(
                lambda m: self.assignments.get(m.group(1) or m.group(2), m.group(0)), text
            )
            if filled == text:
                break
            text = filled
        return os.path.expanduser(text)

    def _sources_for(self, path: str) -> list[str]:
        """`path` を同じコマンド内で作っている生成元を返す。"""
        target = _normalize(path)
        if not target:
            return []
        sources: list[str] = []
        for dst, srcs in self.producers:
            resolved = _normalize(self.expand(dst))
            if resolved == target:
                sources += srcs
            elif resolved == os.path.dirname(target):
                # `cp src dir/` の形。同じ basename の生成元だけが本文になる。
                sources += [
                    s for s in srcs
                    if os.path.basename(self.expand(s)) == os.path.basename(target)
                ]
        return sources

    def read(self, path: str, _hops: int = 0) -> str | None:
        candidate = self.expand(path)
        text = _read_file(candidate)
        if text is not None:
            return text
        if _hops >= MAX_HOPS:
            return None
        for src in self._sources_for(candidate):
            text = self.read(src, _hops + 1)
            if text is not None:
                return text
        return None
