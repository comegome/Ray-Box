#!/usr/bin/env bash
# Ray-Box Manager —— Xray 翻转版
# 拓扑：Xray(Reality) 独占 443，未认证 TLS 原样转发到 127.0.0.1:<FLIP_PORT> 的 Caddy 站点。
# 与 Simple-Box 同一套拓扑（翻转），区别只在核心：这里用 Xray，simbo 用 sing-box。
set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; PLAIN=$'\033[0m'; GRAY=$'\033[0;90m'; BOLD=$'\033[1m'

CONF_DIR="/etc/raybox"
ENV_FILE="${CONF_DIR}/env.conf"
WEB_DIR="${CONF_DIR}/web"
TEMPLATE_FILE="${CONF_DIR}/template.yaml"
XRAY_CONF="/usr/local/etc/xray/config.json"
CADDY_DIR="/etc/caddy"
SITE_FILE="${CADDY_DIR}/sites/raybox-site.caddy"
SUB_FILE="${CADDY_DIR}/sites/raybox-sub.caddy"
TEMPLATE_URL="https://raw.githubusercontent.com/comegome/Ray-Box/main/template.yaml"

pause() { read -r -p "按回车键返回..." _ || true; }

load_env() {
    [[ -f "$ENV_FILE" ]] || return 1
    set +u
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set -u
    VL_PORT="${VL_PORT:-443}"
    FLIP_PORT="${FLIP_PORT:-9443}"
    VL_SNI="${VL_SNI:-$DOMAIN}"
    SUB_PORT="${SUB_PORT:-8444}"
    SUB_DOMAIN="${SUB_DOMAIN:-$DOMAIN}"
    TLS_CERT="${TLS_CERT:-}"
    TLS_KEY="${TLS_KEY:-}"
    DIRECT_SUFFIXES="${DIRECT_SUFFIXES:-}"
    return 0
}

save_env() {
    mkdir -p "$CONF_DIR"
    cat > "$ENV_FILE" <<EOF
DOMAIN="${DOMAIN}"
SITE_ROOT="${SITE_ROOT}"
VL_PORT="${VL_PORT}"
VL_SNI="${VL_SNI}"
FLIP_PORT="${FLIP_PORT}"
SUB_DOMAIN="${SUB_DOMAIN}"
SUB_PORT="${SUB_PORT}"
TLS_CERT="${TLS_CERT:-}"
TLS_KEY="${TLS_KEY:-}"
DIRECT_SUFFIXES="${DIRECT_SUFFIXES:-}"
NODE_NAME="${NODE_NAME}"
UUID="${UUID}"
REALITY_PRIV="${REALITY_PRIV}"
REALITY_PUB="${REALITY_PUB}"
REALITY_SID="${REALITY_SID}"
SUB_TOKEN="${SUB_TOKEN}"
EOF
    chmod 600 "$ENV_FILE"
}

installed() { [[ -f "$ENV_FILE" ]]; }

# reload/restart 之后必须轮询：systemctl reload 返回 0 只代表信号送达，
# 进程可能卡在 reloading，直接当成功会漏掉「重载成功但没生效」。
wait_service_active() {
    local unit="$1" secs="${2:-10}" i
    for ((i = 1; i <= secs; i++)); do
        [[ "$(systemctl is-active "$unit" 2>/dev/null)" == "active" ]] && return 0
        sleep 1
    done
    return 1
}

port_listening() {
    local port="$1" proto="${2:-tcp}"
    if [[ "$proto" == "udp" ]]; then
        ss -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    else
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
    fi
}

gen_uuid() { cat /proc/sys/kernel/random/uuid; }

gen_reality_keys() {
    local out
    out=$(xray x25519)
    REALITY_PRIV=$(printf '%s\n' "$out" | awk -F': ' '/^PrivateKey:/{print $2; exit}')
    REALITY_PUB=$(printf '%s\n' "$out" | grep -oP 'Password \(PublicKey\): \K\S+' || true)
    [[ -n "${REALITY_PRIV:-}" && -n "${REALITY_PUB:-}" ]] || return 1
    REALITY_SID=$(openssl rand -hex 8)
}

# ---------------------------------------------------------------- 配置生成
render_xray() {
    local out="$1"
    cat > "$out" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": ${VL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${UUID}", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:${FLIP_PORT}",
          "xver": 0,
          "serverNames": ["${VL_SNI}"],
          "privateKey": "${REALITY_PRIV}",
          "shortIds": ["${REALITY_SID}"]
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
JSON
}

# 站点退到 loopback 的 FLIP_PORT；80 端口给 ACME + 跳转
render_site() {
    local tlsline=""
    [[ -n "${TLS_CERT:-}" && -n "${TLS_KEY:-}" ]] && tlsline=$'\t'"tls ${TLS_CERT} ${TLS_KEY}"$'\\n'
    cat <<CADDY
# Ray-Box 站点（由 raybox.sh 生成，请勿手改）
https://${DOMAIN}:${FLIP_PORT} {
	bind 127.0.0.1
${tlsline}	root * ${SITE_ROOT}
	encode gzip zstd
	try_files {path} {path}.html {path}/index.html
	file_server
	handle_errors {
		rewrite * /404.html
		file_server
	}
}

http://${DOMAIN} {
	redir https://{host}{uri} permanent
}
CADDY
}

render_sub() {
    local tlsline=""
    if [[ "${SUB_DOMAIN}" == "${DOMAIN}" && -n "${TLS_CERT:-}" && -n "${TLS_KEY:-}" ]]; then
        tlsline=$'\t'"tls ${TLS_CERT} ${TLS_KEY}"$'\\n'
    fi
    cat <<CADDY
# Ray-Box 订阅服务（由 raybox.sh 生成，请勿手改）
${SUB_DOMAIN}:${SUB_PORT} {
${tlsline}	root * ${WEB_DIR}
	@sub path /${SUB_TOKEN}/* /${SUB_TOKEN}
	handle @sub {
		header Content-Type "text/plain; charset=utf-8"
		file_server
	}
	handle {
		respond 404
	}
}
CADDY
}

# ---------------------------------------------------------------- 订阅
gen_proxies() {
    cat <<YAML
proxies:
  - name: "${NODE_NAME}"
    type: vless
    server: ${DOMAIN}
    port: ${VL_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${VL_SNI}
    reality-opts:
      public-key: ${REALITY_PUB}
      short-id: ${REALITY_SID}
      # Xray ≥26.9.8 的 REALITY 要求客户端提供 X25519MLKEM768 密钥交换，
      # mihomo 默认不发，缺这一行会静默报 "REALITY authentication failed"。
      support-x25519mlkem768: true
    client-fingerprint: chrome
YAML
}

gen_groups() {
    cat <<YAML

proxy-groups:
  - name: 📌节点选择
    type: select
    proxies: [♻️自动选择, "${NODE_NAME}"]
  - name: ♻️自动选择
    type: url-test
    url: "https://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50
    proxies: ["${NODE_NAME}"]
YAML
}

gen_links() {
    echo "vless://${UUID}@${DOMAIN}:${VL_PORT}?encryption=none&security=reality&sni=${VL_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp&flow=xtls-rprx-vision&support-x25519mlkem768=true#${NODE_NAME}"
}

gen_singbox() {
    cat <<YAML
outbounds:
  - type: vless
    tag: "${NODE_NAME}"
    server: ${DOMAIN}
    server_port: ${VL_PORT}
    uuid: ${UUID}
    flow: xtls-rprx-vision
    tls:
      enabled: true
      server_name: ${VL_SNI}
      utls:
        enabled: true
        fingerprint: chrome
      reality:
        enabled: true
        public_key: ${REALITY_PUB}
        short_id: ${REALITY_SID}
YAML
}

ensure_template() {
    [[ -f "$TEMPLATE_FILE" ]] && return 0
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [[ -f "${d}/template.yaml" ]] && cp -f "${d}/template.yaml" "$TEMPLATE_FILE" && return 0
    curl -fsSL "$TEMPLATE_URL" -o "$TEMPLATE_FILE" 2>/dev/null && return 0
    return 1
}

build_full_config() {
    local out="$1"
    ensure_template || { echo -e "${RED}模板获取失败${PLAIN}" >&2; return 1; }
    cat "$TEMPLATE_FILE" > "$out"
    local rules="  - DOMAIN,${DOMAIN},DIRECT" s
    for s in ${DIRECT_SUFFIXES:-}; do rules+=$'\n'"  - DOMAIN-SUFFIX,${s},DIRECT"; done
    if grep -q '^rules:' "$out"; then
        awk -v rule="$rules" '{print} /^rules:[[:space:]]*$/ && !done {print rule; done=1}' "$out" > "${out}.tmp" \
            && mv -f "${out}.tmp" "$out"
    else
        printf 'rules:\n%s\n' "$rules" >> "$out"
    fi
    local fip=$'    - "+.'"${DOMAIN}"$'"\n'
    for s in ${DIRECT_SUFFIXES:-}; do fip+=$'    - "+.'"${s}"$'"\n'; done
    if grep -q '^  fake-ip-filter:' "$out"; then
        printf '%s' "$fip" > "${out}.fip"
        awk -v f="${out}.fip" '{print} /^  fake-ip-filter:[[:space:]]*$/ && !d {while ((getline l < f) > 0) print l; close(f); d=1}' \
            "$out" > "${out}.tmp" && mv -f "${out}.tmp" "$out"
        rm -f "${out}.fip"
    fi
    { echo ""; echo "# ==================== Ray-Box 动态生成 ===================="; gen_proxies; gen_groups; } >> "$out"
}

sub_urls() {
    local sd="${SUB_DOMAIN:-$DOMAIN}"
    echo "   mihomo/Clash   https://${sd}:${SUB_PORT}/${SUB_TOKEN}/mihomo.yaml"
    echo "   provider       https://${sd}:${SUB_PORT}/${SUB_TOKEN}/provider.yaml"
    echo "   sing-box       https://${sd}:${SUB_PORT}/${SUB_TOKEN}/singbox.yaml"
    echo "   原生 vless     https://${sd}:${SUB_PORT}/${SUB_TOKEN}/links.txt"
}

write_sub_files() {
    local dir="${WEB_DIR}/${SUB_TOKEN}"
    mkdir -p "$dir"
    build_full_config "${dir}/mihomo.yaml" || return 1
    gen_proxies > "${dir}/provider.yaml"
    gen_singbox > "${dir}/singbox.yaml"
    gen_links > "${dir}/links.txt"
    chmod -R 755 "$WEB_DIR" 2>/dev/null || true
    chmod 644 "${dir}"/* 2>/dev/null || true
}

# ---------------------------------------------------------------- 应用
apply_all() {
    load_env || return 1
    local tmp
    tmp=$(mktemp --suffix=.json)
    render_xray "$tmp"
    if ! xray run -test -c "$tmp" >/tmp/raybox-test.log 2>&1; then
        echo -e "${RED}✗ Xray 配置校验失败${PLAIN}"; tail -5 /tmp/raybox-test.log; rm -f "$tmp"; return 1
    fi
    mkdir -p "$(dirname "$XRAY_CONF")"
    mv "$tmp" "$XRAY_CONF"
    if id xray >/dev/null 2>&1; then chown xray:xray "$XRAY_CONF"; chmod 640 "$XRAY_CONF"; else chmod 644 "$XRAY_CONF"; fi
    echo -e "${GREEN}✓ Xray 配置已写入${PLAIN}"

    write_sub_files || return 1
    render_site > "$SITE_FILE"
    render_sub > "$SUB_FILE"

    if ! caddy validate --config "${CADDY_DIR}/Caddyfile" >/tmp/raybox-caddy.log 2>&1; then
        echo -e "${RED}✗ Caddy 校验失败，未重载${PLAIN}"; tail -5 /tmp/raybox-caddy.log; return 1
    fi
    systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
    wait_service_active caddy 10 || { systemctl restart caddy 2>/dev/null || true; wait_service_active caddy 10 || true; }

    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray 2>/dev/null || { echo -e "${RED}✗ Xray 启动失败${PLAIN}"; return 1; }
    wait_service_active xray 10 || { echo -e "${RED}✗ Xray 未能稳定运行${PLAIN}"; return 1; }
    echo -e "${GREEN}✓ Xray 已重启，Caddy 已重载${PLAIN}"
}

# ---------------------------------------------------------------- 自检
self_check() {
    load_env || return 1
    local ok=0
    echo -e "${BOLD}端口${PLAIN}"
    if port_listening "$VL_PORT" tcp; then echo -e "  ${GREEN}✓${PLAIN} xray 正在监听 ${VL_PORT}"; else echo -e "  ${RED}✗${PLAIN} ${VL_PORT} 没有监听"; ok=1; fi
    if port_listening "$FLIP_PORT" tcp; then echo -e "  ${GREEN}✓${PLAIN} caddy 正在监听 127.0.0.1:${FLIP_PORT}"; else echo -e "  ${RED}✗${PLAIN} ${FLIP_PORT} 没有监听"; ok=1; fi
    if port_listening "$SUB_PORT" tcp; then echo -e "  ${GREEN}✓${PLAIN} 订阅端口 ${SUB_PORT} 正常"; else echo -e "  ${RED}✗${PLAIN} 订阅端口 ${SUB_PORT} 无监听"; ok=1; fi

    echo -e "${BOLD}回落（未认证 TLS 应拿到真实站点）${PLAIN}"
    local code
    code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' --resolve "${DOMAIN}:${VL_PORT}:127.0.0.1" "https://${DOMAIN}/" || true)
    if [[ "$code" == "200" ]]; then echo -e "  ${GREEN}✓${PLAIN} ${VL_PORT} 回落站点 200"; else echo -e "  ${RED}✗${PLAIN} ${VL_PORT} 回落返回 ${code:-超时}"; ok=1; fi

    echo -e "${BOLD}证书（探测者看到的名字）${PLAIN}"
    local cn
    cn=$(echo | openssl s_client -connect "127.0.0.1:${VL_PORT}" -servername "$DOMAIN" 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed 's/.*CN *= *//' || true)
    if [[ "$cn" == "$DOMAIN" ]]; then echo -e "  ${GREEN}✓${PLAIN} CN=${cn}"; else echo -e "  ${RED}✗${PLAIN} CN=${cn:-读取失败}（期望 ${DOMAIN}）"; ok=1; fi

    echo -e "${BOLD}订阅${PLAIN}"
    local scode
    scode=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "https://${SUB_DOMAIN}:${SUB_PORT}/${SUB_TOKEN}/provider.yaml" || true)
    if [[ "$scode" == "200" ]]; then echo -e "  ${GREEN}✓${PLAIN} 订阅 200"; else echo -e "  ${RED}✗${PLAIN} 订阅返回 ${scode:-失败}"; ok=1; fi

    echo ""
    if (( ok == 0 )); then echo -e "${GREEN}全部通过${PLAIN}（真实连通性仍需客户端验证）"; else echo -e "${YELLOW}存在异常，按上面失败的层级查${PLAIN}"; fi
    return $ok
}

show_info() {
    load_env || return 1
    echo -e "${GRAY}---------------- 节点 ----------------${PLAIN}"
    printf ' %-14s %s\n' "名称" "$NODE_NAME"
    printf ' %-14s %s:%s\n' "入口" "$DOMAIN" "$VL_PORT"
    printf ' %-14s %s\n' "SNI" "$VL_SNI"
    printf ' %-14s %s\n' "回落" "127.0.0.1:${FLIP_PORT}"
    printf ' %-14s %s\n' "UUID" "$UUID"
    printf ' %-14s %s\n' "公钥" "$REALITY_PUB"
    printf ' %-14s %s\n' "ShortID" "$REALITY_SID"
    echo -e "${GRAY}--------------- 站点 ----------------${PLAIN}"
    printf ' %-14s %s\n' "目录" "$SITE_ROOT"
    printf ' %-14s %s\n' "内部端口" "127.0.0.1:${FLIP_PORT}"
}

# ---------------------------------------------------------------- 菜单
menu_sub() {
    while true; do
        [ -t 1 ] && clear
        load_env
        echo -e "${GRAY}====================== 订阅地址 ======================${PLAIN}"
        sub_urls
        echo -e "${GRAY}======================================================${PLAIN}"
        echo " 1. 重新生成订阅文件"
        echo " 2. 重置订阅 token"
        echo " 0. 返回"
        local opt=""; read -r -p "请输入选项 [0-2]: " opt || opt="0"
        case "$opt" in
            1) write_sub_files && echo -e "${GREEN}✓ 已重新生成${PLAIN}"; pause ;;
            2) SUB_TOKEN=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'); save_env
               rm -rf "$WEB_DIR"; write_sub_files; render_sub > "$SUB_FILE"
               if caddy validate --config "${CADDY_DIR}/Caddyfile" >/dev/null 2>&1; then
                   systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
               fi
               echo -e "${GREEN}✓ token 已重置${PLAIN}"; pause ;;
            0) break ;;
        esac
    done
}

menu_core() {
    while true; do
        [ -t 1 ] && clear
        echo -e "${GRAY}====================== 内核 ======================${PLAIN}"
        echo " 1. 重启 Xray"
        echo " 2. 检查并更新 Xray"
        echo " 3. 查看最近 40 行日志"
        echo " 0. 返回"
        local opt=""; read -r -p "请输入选项 [0-3]: " opt || opt="0"
        case "$opt" in
            1) systemctl restart xray && echo -e "${GREEN}✓ 已重启${PLAIN}"; pause ;;
            2) bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/raybox-xray-update.log 2>&1
               echo -e "${GREEN}✓ 当前 $(xray version | head -1)${PLAIN}"; systemctl restart xray || true; pause ;;
            3) journalctl -u xray -o cat -n 40 --no-pager || true; pause ;;
            0) break ;;
        esac
    done
}

menu_edit() {
    while true; do
        [ -t 1 ] && clear
        load_env
        echo -e "${GRAY}====================== 修改配置 ======================${PLAIN}"
        echo " 1. 改入口端口（当前 ${VL_PORT}）"
        echo " 2. 改 SNI（当前 ${VL_SNI}）"
        echo " 3. 重置 UUID"
        echo " 4. 重建 Reality 密钥"
        echo " 0. 返回"
        local opt="" v; read -r -p "请输入选项 [0-4]: " opt || opt="0"
        case "$opt" in
            1) read -r -p "新端口 [${VL_PORT}]: " v; v=${v:-$VL_PORT}
               if [[ ! "$v" =~ ^[0-9]+$ ]] || (( v < 1 || v > 65535 )); then echo "端口无效"; pause; continue; fi
               VL_PORT="$v"; save_env; apply_all; pause ;;
            2) read -r -p "新 SNI [${VL_SNI}]: " v; v=${v:-$VL_SNI}
               if [[ ! "$v" =~ ^[A-Za-z0-9.-]+$ ]]; then echo "域名格式无效"; pause; continue; fi
               VL_SNI="$v"; save_env; apply_all; pause ;;
            3) UUID=$(gen_uuid); save_env; apply_all; echo -e "${GREEN}✓ UUID 已重置${PLAIN}"; pause ;;
            4) if gen_reality_keys; then save_env; apply_all; echo -e "${GREEN}✓ 密钥已重建${PLAIN}"; fi; pause ;;
            0) break ;;
        esac
    done
}

menu() {
    while true; do
        [ -t 1 ] && clear
        load_env || true
        echo -e "${GRAY}======================================================${PLAIN}"
        show_info
        echo -e "${GRAY}======================================================${PLAIN}"
        echo " 1. 节点与站点信息"
        echo " 2. 订阅地址"
        echo " 3. 内核与服务"
        echo " 4. 自检"
        echo " 5. 修改配置"
        echo " 6. 卸载"
        echo " 0. 退出"
        local opt=""; read -r -p "请输入选项 [0-6]: " opt || opt="0"
        case "$opt" in
            1) [ -t 1 ] && clear; show_info; echo ""; sub_urls; pause ;;
            2) menu_sub ;;
            3) menu_core ;;
            4) [ -t 1 ] && clear; self_check; pause ;;
            5) menu_edit ;;
            6) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

uninstall_all() {
    echo -e "${YELLOW}将停止 Xray、删除 ${CONF_DIR}、站点块与订阅块。${PLAIN}"
    echo -e "${YELLOW}站点目录 ${SITE_ROOT} 不会被删除。${PLAIN}"
    local c=""; read -r -p "确认卸载吗？(y/N): " c || c=""
    [[ "$c" != "y" && "$c" != "Y" ]] && { echo "已取消"; return 0; }
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    rm -f "$XRAY_CONF" "$SITE_FILE" "$SUB_FILE"
    rm -rf "$CONF_DIR"
    if caddy validate --config "${CADDY_DIR}/Caddyfile" >/dev/null 2>&1; then
        systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true
    fi
    rm -f /usr/local/bin/raybox
    rm -rf /usr/local/share/ray-box
    echo -e "${GREEN}✓ 已卸载（站点目录保留）${PLAIN}"
    exit 0
}

install_xray() {
    if command -v xray >/dev/null 2>&1; then echo -e "${GREEN}✓ 已安装 $(xray version | head -1)${PLAIN}"; return 0; fi
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/raybox-xray-install.log 2>&1 || true
    command -v xray >/dev/null 2>&1 || { echo -e "${RED}✗ Xray 安装失败，见 /tmp/raybox-xray-install.log${PLAIN}"; return 1; }
    echo -e "${GREEN}✓ Xray 安装完成${PLAIN}"
}

install_wizard() {
    echo -e "${BOLD}Ray-Box 安装向导（Reality 翻转）${PLAIN}"
    local domain site port flip subdomain subport
    read -r -p "站点域名（同时作为 Reality SNI）: " domain || domain=""
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || { echo -e "${RED}域名格式无效${PLAIN}"; return 1; }
    local guess="/var/www/$(printf '%s' "$domain" | cut -d. -f1)"
    read -r -p "站点根目录 [${guess}]: " site || site=""
    site=${site:-$guess}
    [[ -d "$site" ]] || { echo -e "${RED}目录不存在: ${site}${PLAIN}"; return 1; }
    read -r -p "Reality 监听端口 [443]: " port || port=""
    port=${port:-443}
    read -r -p "站点内部端口（Caddy 回落，仅 loopback）[9443]: " flip || flip=""
    flip=${flip:-9443}
    read -r -p "订阅域名 [${domain}]: " subdomain || subdomain=""
    subdomain=${subdomain:-$domain}
    read -r -p "订阅端口 [8444]: " subport || subport=""
    subport=${subport:-8444}

    DOMAIN="$domain"; SITE_ROOT="$site"; VL_PORT="$port"; FLIP_PORT="$flip"
    VL_SNI="$domain"; SUB_DOMAIN="$subdomain"; SUB_PORT="$subport"
    NODE_NAME="$(printf '%s' "$domain" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')-Reality"
    UUID=$(gen_uuid)
    gen_reality_keys || { echo -e "${RED}Reality 密钥生成失败${PLAIN}"; return 1; }
    SUB_TOKEN=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    install_xray || return 1
    ensure_template || { echo -e "${RED}模板获取失败${PLAIN}"; return 1; }
    save_env
    apply_all || return 1

    mkdir -p /usr/local/share/ray-box
    cp -f "${BASH_SOURCE[0]}" /usr/local/share/ray-box/raybox.sh
    chmod +x /usr/local/share/ray-box/raybox.sh
    ln -sf /usr/local/share/ray-box/raybox.sh /usr/local/bin/raybox
    echo ""
    show_info
    echo ""
    sub_urls
}

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$(readlink -f "$0")" "$@"
fi

if [[ ! -f "$ENV_FILE" ]]; then
    install_wizard || exit 1
fi

case "${1:-}" in
    install|reinstall) install_wizard ;;
    check) self_check ;;
    *) menu ;;
esac
