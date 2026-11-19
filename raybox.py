#!/usr/bin/env python3
"""Ray-Box — VLESS nodes on the Xray core, hidden behind a real HTTPS site.

Two transports, both validated against ClashX Meta (mihomo) and Xray:

  xhttp   VLESS + XHTTP + TLS   best camouflage, mihomo only
  ws      VLESS + WS   + TLS   works with mihomo and sing-box

Optional VLESS Encryption (post-quantum key exchange + length padding) can be
layered on either transport.

The front door is Caddy: it owns 443, serves the site, and reverse-proxies one
path per node to a loopback Xray inbound.
"""
import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import urllib.parse
from pathlib import Path

STATE_PATH = Path(os.environ.get("RAYBOX_STATE", "/etc/raybox/state.json"))
XRAY_CONFIG = Path(os.environ.get("RAYBOX_XRAY_CONFIG", "/usr/local/etc/xray/config.json"))
CADDY_DIR = Path(os.environ.get("RAYBOX_CADDY_DIR", "/etc/caddy/sites"))
BASE_PORT = 10000


# ----------------------------------------------------------------- helpers
def sh(cmd, check=True):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit("命令失败: %s\n%s" % (cmd, (p.stderr or p.stdout).strip()[:500]))
    return p.stdout.strip()


def load_state():
    if not STATE_PATH.exists():
        sys.exit("还没有初始化，先跑: raybox init --domain <域名> --site <站点目录>")
    return json.loads(STATE_PATH.read_text(encoding="utf-8"))


def save_state(st):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(st, ensure_ascii=False, indent=1), encoding="utf-8")
    try:
        STATE_PATH.chmod(0o600)
    except OSError:
        pass


def xray_version():
    try:
        out = sh("xray version", check=False)
        m = re.search(r"Xray (\d+)\.(\d+)\.(\d+)", out)
        return tuple(int(x) for x in m.groups()) if m else None
    except Exception:  # noqa: BLE001
        return None


def gen_encryption(kind):
    """kind: none | x25519 | mlkem. Returns {'server':..., 'client':...} or None."""
    if kind == "none":
        return None
    out = sh("xray vlessenc")
    blocks = out.split("Authentication:")
    want = "ML-KEM" if kind == "mlkem" else "X25519"
    for b in blocks:
        if not b.strip().startswith(want):
            continue
        dec = re.search(r'"decryption":\s*"([^"]+)"', b)
        enc = re.search(r'"encryption":\s*"([^"]+)"', b)
        if dec and enc:
            return {"server": dec.group(1), "client": enc.group(1), "auth": kind}
    sys.exit("无法从 xray vlessenc 输出中解析 %s 参数" % kind)


def new_path(transport):
    return "/assets/" + secrets.token_hex(4)


# ----------------------------------------------------------------- render
def render_xray(st):
    inbounds = []
    for n in st["nodes"]:
        settings = {
            "clients": [{"id": st["uuid"]}],
            "decryption": (n.get("encryption") or {}).get("server") or "none",
        }
        if n["transport"] == "xhttp":
            stream = {"network": "xhttp", "xhttpSettings": {"path": n["path"]}}
        else:
            stream = {"network": "ws", "wsSettings": {"path": n["path"]}}
        inbounds.append({
            "tag": "node-" + n["name"],
            "listen": "127.0.0.1",
            "port": n["port"],
            "protocol": "vless",
            "settings": settings,
            "streamSettings": stream,
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        })
    return {
        "log": {"loglevel": "warning"},
        "inbounds": inbounds,
        "outbounds": [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"},
        ],
    }


def render_caddy(st):
    domain = st["domain"]
    port = st.get("front_port", 443)
    addr = domain if port == 443 else "%s:%s" % (domain, port)
    lines = [
        "# Ray-Box — 由 raybox.py 生成，请勿手改",
        "%s {" % addr,
        "\troot * %s" % st["site_root"],
    ]
    for i, n in enumerate(st["nodes"]):
        matcher = "@rb%d" % i
        lines.append("\t%s path %s %s/*" % (matcher, n["path"], n["path"]))
        lines.append("\thandle %s {" % matcher)
        lines.append("\t\treverse_proxy 127.0.0.1:%d" % n["port"])
        lines.append("\t}")
    lines += [
        "\thandle {",
        "\t\tencode gzip zstd",
        "\t\tfile_server",
        "\t}",
        "\thandle_errors {",
        "\t\trewrite * /404.html",
        "\t\tfile_server",
        "\t}",
        "\theader Cache-Control \"public, max-age=60, must-revalidate\"",
        "}",
    ]
    return "\n".join(lines) + "\n"


def mihomo_yaml(st):
    out = ["proxies:"]
    for n in st["nodes"]:
        enc = (n.get("encryption") or {}).get("client")
        out += [
            "  - name: \"%s\"" % n["name"],
            "    type: vless",
            "    server: %s" % st["domain"],
            "    port: %d" % st.get("front_port", 443),
            "    uuid: %s" % st["uuid"],
            "    network: %s" % n["transport"],
            "    udp: true",
            "    tls: true",
            "    servername: %s" % st["domain"],
            "    client-fingerprint: chrome",
        ]
        if enc:
            out.append("    encryption: \"%s\"" % enc)
        if n["transport"] == "xhttp":
            out += ["    xhttp-opts:",
                    "      path: \"%s\"" % n["path"],
                    "      host: %s" % st["domain"]]
        else:
            out += ["    ws-opts:",
                    "      path: \"%s\"" % n["path"],
                    "      headers:",
                    "        Host: %s" % st["domain"]]
    out += ["", "proxy-groups:",
            "  - name: PROXY",
            "    type: select",
            "    proxies: [%s]" % ", ".join('"%s"' % n["name"] for n in st["nodes"]),
            "", "rules:", "  - MATCH,PROXY"]
    return "\n".join(out) + "\n"


def singbox_yaml(st):
    out = ["outbounds:"]
    skipped = []
    for n in st["nodes"]:
        if n["transport"] != "ws":
            skipped.append("%s（XHTTP）" % n["name"])
            continue
        if n.get("encryption"):
            skipped.append("%s（VLESS Encryption）" % n["name"])
            continue
        out += [
            "  - type: vless",
            "    tag: \"%s\"" % n["name"],
            "    server: %s" % st["domain"],
            "    server_port: %d" % st.get("front_port", 443),
            "    uuid: %s" % st["uuid"],
            "    tls:",
            "      enabled: true",
            "      server_name: %s" % st["domain"],
            "    transport:",
            "      type: ws",
            "      path: \"%s\"" % n["path"],
            "      headers:",
            "        Host: %s" % st["domain"],
        ]
    if skipped:
        out.insert(0, "# 以下节点是 XHTTP，sing-box 不支持，已跳过: %s" % ", ".join(skipped))
    return "\n".join(out) + "\n"


def node_link(st, n):
    enc = (n.get("encryption") or {}).get("client") or "none"
    q = {
        "encryption": enc,
        "security": "tls",
        "sni": st["domain"],
        "fp": "chrome",
        "type": n["transport"],
        "path": n["path"],
        "host": st["domain"],
    }
    return "vless://%s@%s:%d?%s#%s" % (
        st["uuid"], st["domain"], st.get("front_port", 443),
        urllib.parse.urlencode(q, quote_via=urllib.parse.quote), n["name"])


# ----------------------------------------------------------------- commands
def cmd_init(a):
    st = {
        "domain": a.domain,
        "site_root": a.site,
        "front_port": a.front_port,
        "uuid": sh("xray uuid"),
        "sub_token": secrets.token_hex(16),
        "nodes": [],
    }
    save_state(st)
    print("已初始化 %s" % STATE_PATH)
    print("  域名    %s" % st["domain"])
    print("  站点    %s" % st["site_root"])
    print("  端口    %s" % st["front_port"])
    print("  UUID    %s" % st["uuid"])
    print("\n下一步: raybox add-node --transport xhttp --encryption x25519")


def cmd_add(a):
    st = load_state()
    if any(n["name"] == a.name for n in st["nodes"]):
        sys.exit("节点名已存在: %s" % a.name)
    if a.transport not in ("xhttp", "ws"):
        sys.exit("transport 只能是 xhttp 或 ws")
    used = {n["port"] for n in st["nodes"]}
    port = a.port or next(p for p in range(BASE_PORT, BASE_PORT + 200) if p not in used)
    node = {
        "name": a.name,
        "transport": a.transport,
        "path": a.path or new_path(a.transport),
        "port": port,
        "encryption": gen_encryption(a.encryption),
    }
    st["nodes"].append(node)
    save_state(st)
    print("已添加 %s（%s，端口 %d，路径 %s）" % (node["name"], node["transport"], port, node["path"]))
    print("加密: %s" % (node["encryption"]["auth"] if node["encryption"] else "关闭"))
    print("执行 raybox apply 生效")


def cmd_del(a):
    st = load_state()
    before = len(st["nodes"])
    st["nodes"] = [n for n in st["nodes"] if n["name"] != a.name]
    if len(st["nodes"]) == before:
        sys.exit("没有这个节点: %s" % a.name)
    save_state(st)
    print("已删除 %s，执行 raybox apply 生效" % a.name)


def cmd_apply(a):
    st = load_state()
    cfg = render_xray(st)
    XRAY_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    tmp = Path("/tmp/raybox-xray.json")
    tmp.write_text(json.dumps(cfg, ensure_ascii=False, indent=1), encoding="utf-8")
    sh("xray run -test -c %s" % tmp)
    XRAY_CONFIG.write_text(json.dumps(cfg, ensure_ascii=False, indent=1), encoding="utf-8")

    caddy_text = render_caddy(st)
    if a.print_caddy:
        print(caddy_text)
    else:
        target = CADDY_DIR / "raybox.caddy"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(caddy_text, encoding="utf-8")
        print("已写入 %s" % target)

    if not a.no_restart:
        sh("systemctl restart xray", check=False)
        print("xray 已重启")
        if not a.print_caddy:
            p = subprocess.run("caddy validate --config /etc/caddy/Caddyfile",
                               shell=True, capture_output=True, text=True)
            if p.returncode == 0:
                sh("systemctl reload caddy", check=False)
                print("caddy 已重载")
            else:
                print("Caddy 配置有问题，未重载:\n%s" % (p.stderr or p.stdout)[-400:])

    print("\n节点：")
    for n in st["nodes"]:
        print("  %-14s %-5s :%d  %s" % (n["name"], n["transport"], n["port"], n["path"]))


def cmd_sub(a):
    st = load_state()
    fmt = a.format
    if fmt in ("mihomo", "all"):
        print("# ===== mihomo / ClashX Meta =====")
        print(mihomo_yaml(st))
    if fmt in ("singbox", "all"):
        print("# ===== sing-box =====")
        print(singbox_yaml(st))
    if fmt in ("links", "all"):
        print("# ===== vless:// =====")
        for n in st["nodes"]:
            print(node_link(st, n))


def cmd_status(a):
    st = load_state()
    print("域名   %s:%s" % (st["domain"], st.get("front_port", 443)))
    print("站点   %s" % st["site_root"])
    print("Xray   %s" % (sh("systemctl is-active xray", check=False) or "未知"))
    print("Caddy  %s" % (sh("systemctl is-active caddy", check=False) or "未知"))
    print("节点   %d 个" % len(st["nodes"]))
    for n in st["nodes"]:
        enc = (n.get("encryption") or {}).get("auth", "off")
        print("  %-14s %-5s :%d  %-22s enc=%s" % (n["name"], n["transport"], n["port"], n["path"], enc))


def main():
    ap = argparse.ArgumentParser(prog="raybox", description="Ray-Box: VLESS on Xray behind a real site")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("init", help="初始化")
    p.add_argument("--domain", required=True)
    p.add_argument("--site", required=True, help="站点根目录，Caddy 从这里取文件")
    p.add_argument("--front-port", type=int, default=443)
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("add-node", help="添加节点")
    p.add_argument("--transport", required=True, choices=["xhttp", "ws"])
    p.add_argument("--name", required=True)
    p.add_argument("--path", help="默认随机 /assets/<hex>")
    p.add_argument("--port", type=int, help="默认从 10000 递增")
    p.add_argument("--encryption", default="none", choices=["none", "x25519", "mlkem"])
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("del-node", help="删除节点")
    p.add_argument("--name", required=True)
    p.set_defaults(func=cmd_del)

    p = sub.add_parser("apply", help="生成配置并重启")
    p.add_argument("--print-caddy", action="store_true", help="只打印 Caddy 块，不写入")
    p.add_argument("--no-restart", action="store_true")
    p.set_defaults(func=cmd_apply)

    p = sub.add_parser("sub", help="输出订阅")
    p.add_argument("--format", default="all", choices=["mihomo", "singbox", "links", "all"])
    p.set_defaults(func=cmd_sub)

    p = sub.add_parser("status", help="查看状态")
    p.set_defaults(func=cmd_status)

    a = ap.parse_args()
    v = xray_version()
    if v and v < (25, 1, 0) and a.cmd != "status":
        print("警告: Xray %s 版本偏低，VLESS Encryption 需要较新版本" % ".".join(map(str, v)), file=sys.stderr)
    a.func(a)


if __name__ == "__main__":
    main()
