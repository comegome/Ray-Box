#!/usr/bin/env python3
"""在已有的 Caddy 站点块里插入/移除 Ray-Box 的反代路由（不重写站点本身）。

用法：
  raybox-attach.py attach --caddy-dir /etc/caddy --domain example.com \
      --snippet /etc/caddy/snippets/raybox.caddy [--backup]
  raybox-attach.py detach --caddy-dir /etc/caddy --domain example.com

约定：
  * 只动 Sites 目录里**已经存在该域名站点块**的文件；找不到就退出码 2，不乱插。
  * 注入的是一行 `import <snippet>  # raybox-attach`，站点其余字节不变。
  * 幂等：标记行已存在就不写文件、不改 mtime。
  * detach 只删这两行，返回前调用方应做 caddy validate。
"""

import argparse
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

MARKER = "# raybox-attach"
SNIPPET_MARKER = "# raybox-snippet"


def die(msg, code=1):
    print("错误: %s" % msg, file=sys.stderr)
    sys.exit(code)


def strip_comment(line):
    """去掉行内注释（# 之后），但保留引号内的 #。"""
    out, in_str, esc = [], False, False
    for ch in line:
        if in_str:
            out.append(ch)
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            out.append(ch)
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out)


def site_files(caddy_dir):
    sites = Path(caddy_dir) / "sites"
    if not sites.is_dir():
        return []
    return sorted(p for p in sites.iterdir() if p.is_file() and p.suffix == ".caddy")


def addresses_of(line):
    """站点块首行里 { 之前的部分，按逗号拆成地址列表。"""
    code = strip_comment(line)
    brace = code.find("{")
    head = code if brace < 0 else code[:brace]
    return [a.strip() for a in head.split(",") if a.strip()]


def bare(addr):
    a = re.sub(r"^[a-z]+://", "", addr, flags=re.I)   # https://
    a = a.split("/", 1)[0]
    a = re.sub(r":\d+$", "", a)                        # :8443
    return a.lower()


def find_block(lines, domain):
    """返回 (start, end)：block 首行下标 与 闭合大括号行的下标（含）。"""
    want = domain.lower()
    for i, line in enumerate(lines):
        addrs = addresses_of(line)
        if not addrs or "{" not in strip_comment(line):
            continue
        if not any(bare(a) == want for a in addrs):
            continue
        depth, in_str, esc = 0, False, False
        for j in range(i, len(lines)):
            for ch in lines[j]:
                if in_str:
                    if esc:
                        esc = False
                    elif ch == "\\":
                        esc = True
                    elif ch == '"':
                        in_str = False
                    continue
                if ch == '"':
                    in_str = True
                elif ch == "#":
                    break          # 行内注释，本行剩余不再计数
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        return i, j
        return i, None
    return None, None


def find_site_file(caddy_dir, domain):
    for path in site_files(caddy_dir):
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        start, end = find_block(lines, domain)
        if start is not None:
            return path, lines, start, end
    return None, None, None, None


def indent_of(line):
    return line[: len(line) - len(line.lstrip(" \t"))]


def do_attach(args):
    path, lines, start, end = find_site_file(args.caddy_dir, args.domain)
    if path is None:
        die("在 %s/sites 里没找到 %s 的站点块（用 standalone 模式）" % (args.caddy_dir, args.domain), 2)
    if end is None:
        die("%s 的站点块大括号不配平，拒绝修改" % path, 3)

    snippet = Path(args.snippet).resolve()
    if not snippet.is_file():
        die("snippet 不存在: %s" % snippet, 4)

    body = "".join(lines[start : end + 1])
    if MARKER in body:
        print("already-attached %s" % path)
        return 0

    new_line = "%s\timport %s  %s\n" % (indent_of(lines[start]), snippet, MARKER)
    # 插在站点块首行的下一行（即所有 handler 之前，保证 handle 先于 file_server）
    lines.insert(start + 1, new_line)

    if args.backup:
        bak = "%s.raybox-bak-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
        shutil.copy2(path, bak)
        print("backup %s" % bak)

    tmp = path.with_suffix(path.suffix + ".raybox-tmp")
    tmp.write_text("".join(lines), encoding="utf-8")
    tmp.replace(path)

    if args.manifest:
        Path(args.manifest).parent.mkdir(parents=True, exist_ok=True)
        Path(args.manifest).write_text(
            json.dumps({"site_file": str(path), "domain": args.domain,
                        "snippet": str(snippet), "line": new_line.strip(),
                        "written_at": time.strftime("%FT%TZ", time.gmtime())},
                       ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print("attached %s" % path)
    return 0


def do_detach(args):
    path, lines, start, end = find_site_file(args.caddy_dir, args.domain)
    if path is None:
        die("没找到 %s 的站点块" % args.domain, 2)
    if end is None:
        die("%s 大括号不配平，拒绝修改" % path, 3)

    body = lines[start : end + 1]
    if MARKER not in "".join(body):
        print("not-attached %s" % path)
        return 0

    if args.backup:
        bak = "%s.raybox-bak-%s" % (path, time.strftime("%Y%m%d%H%M%S"))
        shutil.copy2(path, bak)

    kept = [ln for ln in lines if MARKER not in ln]
    if len(kept) == len(lines):
        die("标记行没删掉，文件未写入", 5)
    tmp = path.with_suffix(path.suffix + ".raybox-tmp")
    tmp.write_text("".join(kept), encoding="utf-8")
    tmp.replace(path)
    print("detached %s" % path)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("attach")
    a.add_argument("--caddy-dir", required=True)
    a.add_argument("--domain", required=True)
    a.add_argument("--snippet", required=True)
    a.add_argument("--backup", action="store_true")
    a.add_argument("--manifest")
    a.set_defaults(func=do_attach)

    d = sub.add_parser("detach")
    d.add_argument("--caddy-dir", required=True)
    d.add_argument("--domain", required=True)
    d.add_argument("--backup", action="store_true")
    d.set_defaults(func=do_detach)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
