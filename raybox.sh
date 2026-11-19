#!/usr/bin/env bash
# ==============================================================================
# Ray-Box Manager - 基于 Xray 核心的 VLESS 节点管理脚本
# 协议支持:
#   1. VLESS + XHTTP + TLS   （伪装最好，仅 mihomo / ClashX Meta 系客户端）
#   2. VLESS + WS   + TLS   （mihomo 与 sing-box 都支持）
# 可选: VLESS Encryption（后量子密钥交换 + 长度填充）
# 架构: Caddy 占 443 提供真实站点与证书，按路径反代到 loopback 上的 Xray
# ==============================================================================
set -uo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
PLAIN=$'\033[0m'
GRAY=$'\033[0;90m'
BOLD=$'\033[1m'

CONF_DIR="/etc/raybox"
ENV_FILE="${CONF_DIR}/env.conf"
NODES_FILE="${CONF_DIR}/nodes.conf"
WEB_DIR="${CONF_DIR}/web"
XRAY_CONF="/usr/local/etc/xray/config.json"
CADDY_SITE="/etc/caddy/sites/raybox.caddy"
SCRIPT_URL="https://raw.githubusercontent.com/comegome/Ray-Box/main/raybox.sh"

# 管道执行时 bash 与 read 抢同一条 stdin，提问会把脚本正文当答案吃掉
if [[ -z "${BASH_SOURCE[0]:-}" ]]; then
    cat >/dev/null 2>&1 || true
    echo -e "${RED}不支持管道执行（curl ... | bash）。${PLAIN}"
    echo -e "${YELLOW}请先下载再运行：${PLAIN}"
    echo -e "  curl -fsSL ${SCRIPT_URL} -o /tmp/raybox.sh && sudo bash /tmp/raybox.sh"
    exit 1
fi

[[ $EUID -ne 0 ]] && echo -e "${RED}错误: 必须使用 root 权限运行${PLAIN}" && exit 1

get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) return 1 ;;
    esac
}

require_os() {
    [[ -f /etc/os-release ]] || { echo -e "${RED}无法识别系统${PLAIN}"; return 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) echo "${PRETTY_NAME:-$ID}" ;;
        *) echo -e "${RED}仅支持 Ubuntu / Debian，当前: ${PRETTY_NAME:-unknown}${PLAIN}"; return 1 ;;
    esac
}

pause() { read -r -p "按回车键返回..." _ || true; }

# ---------------------------------------------------------------- 状态读写
load_env() {
    [[ -f "$ENV_FILE" ]] || return 1
    set +u
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set -u
    return 0
}

save_env() {
    mkdir -p "$CONF_DIR"
    cat > "$ENV_FILE" <<EOF
DOMAIN="${DOMAIN}"
SITE_ROOT="${SITE_ROOT}"
FRONT_PORT="${FRONT_PORT}"
UUID="${UUID}"
SUB_TOKEN="${SUB_TOKEN}"
EOF
    chmod 600 "$ENV_FILE"
}

installed() { [[ -f "$ENV_FILE" ]]; }

node_count() {
    [[ -f "$NODES_FILE" ]] || { echo 0; return; }
    grep -c . "$NODES_FILE" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------- 工具
rand_path() { echo "/assets/$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

xray_ver() {
    command -v xray >/dev/null 2>&1 || { echo ""; return; }
    xray version 2>/dev/null | head -n1 | awk '{print $2}'
}

gen_enc() {
    # $1 = none|x25519|mlkem ; 输出 "server|client"
    local kind="$1"
    [[ "$kind" == "none" ]] && { echo "none|none"; return; }
    local out want
    out=$(xray vlessenc 2>/dev/null) || { echo "none|none"; return; }
    if [[ "$kind" == "mlkem" ]]; then want="ML-KEM"; else want="X25519"; fi
    local block
    block=$(echo "$out" | awk -v w="$want" '/^Authentication:/{f=($0 ~ w)} f')
    local dec enc
    dec=$(echo "$block" | grep -oP '"decryption":\s*"\K[^"]+' | head -n1)
    enc=$(echo "$block" | grep -oP '"encryption":\s*"\K[^"]+' | head -n1)
    [[ -z "$dec" || -z "$enc" ]] && { echo "none|none"; return; }
    echo "${dec}|${enc}"
}

# ---------------------------------------------------------------- 配置生成
render_xray() {
    local tmp="$1" inbounds="" first=1
    local name transport port path enc_srv enc_cli stream
    if [[ -f "$NODES_FILE" ]]; then
        while IFS='|' read -r name transport port path enc_srv enc_cli; do
            [[ -z "${name:-}" ]] && continue
            if [[ "$transport" == "xhttp" ]]; then
                stream=$(printf '"network":"xhttp","xhttpSettings":{"path":"%s"}' "$path")
            else
                stream=$(printf '"network":"ws","wsSettings":{"path":"%s"}' "$path")
            fi
            [[ $first -eq 1 ]] || inbounds+=","
            first=0
            inbounds+=$(cat <<JSON
{
  "tag": "node-${name}",
  "listen": "127.0.0.1",
  "port": ${port},
  "protocol": "vless",
  "settings": {"clients":[{"id":"${UUID}"}],"decryption":"${enc_srv}"},
  "streamSettings": {${stream}},
  "sniffing": {"enabled":true,"destOverride":["http","tls","quic"]}
}
JSON
)
        done < "$NODES_FILE"
    fi
    cat > "$tmp" <<JSON
{
  "log": {"loglevel": "warning"},
  "inbounds": [${inbounds}],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
JSON
}

render_caddy() {
    local addr="${DOMAIN}"
    [[ "${FRONT_PORT}" != "443" ]] && addr="${DOMAIN}:${FRONT_PORT}"
    local out
    out="# Ray-Box - 由 raybox.sh 生成，请勿手改"$'\n'
    out+="${addr} {"$'\n'
    out+=$'\t'"root * ${SITE_ROOT}"$'\n'
    local name transport port path enc_srv enc_cli i=0
    if [[ -f "$NODES_FILE" ]]; then
        while IFS='|' read -r name transport port path enc_srv enc_cli; do
            [[ -z "${name:-}" ]] && continue
            out+=$'\t'"@rb${i} path ${path} ${path}/*"$'\n'
            out+=$'\t'"handle @rb${i} {"$'\n'
            out+=$'\t\t'"reverse_proxy 127.0.0.1:${port}"$'\n'
            out+=$'\t'"}"$'\n'
            i=$((i+1))
        done < "$NODES_FILE"
    fi
    # encode 只能作用于静态文件：gzip 会缓冲 XHTTP 的流式响应，导致超时
    out+=$'\t'"handle {"$'\n'
    out+=$'\t\t'"encode gzip zstd"$'\n'
    out+=$'\t\t'"file_server"$'\n'
    out+=$'\t'"}"$'\n'
    out+=$'\t'"handle_errors {"$'\n'
    out+=$'\t\t'"rewrite * /404.html"$'\n'
    out+=$'\t\t'"file_server"$'\n'
    out+=$'\t'"}"$'\n'
    out+=$'\t'"header Cache-Control \"public, max-age=60, must-revalidate\""$'\n'
    out+="}"$'\n'
    printf '%s' "$out"
}

apply_all() {
    load_env || return 1
    local tmp
    tmp=$(mktemp --suffix=.json)
    render_xray "$tmp"
    if ! xray run -test -c "$tmp" >/tmp/raybox-test.log 2>&1; then
        echo -e "${RED}✗ Xray 配置校验失败${PLAIN}"
        tail -5 /tmp/raybox-test.log
        rm -f "$tmp"
        return 1
    fi
    mkdir -p "$(dirname "$XRAY_CONF")"
    mv "$tmp" "$XRAY_CONF"
    chmod 600 "$XRAY_CONF"
    echo -e "${GREEN}✓ Xray 配置已写入${PLAIN}"

    if command -v caddy >/dev/null 2>&1; then
        mkdir -p "$(dirname "$CADDY_SITE")"
        render_caddy > "$CADDY_SITE"
        if caddy validate --config /etc/caddy/Caddyfile >/tmp/raybox-caddy.log 2>&1; then
            if systemctl reload caddy 2>/dev/null; then
                echo -e "${GREEN}✓ Caddy 已重载${PLAIN}"
            else
                echo -e "${YELLOW}! Caddy 重载失败（站点块可能占用已被 UDP 使用的端口）${PLAIN}"
            fi
        else
            echo -e "${RED}✗ Caddy 配置校验失败，未重载${PLAIN}"
            tail -5 /tmp/raybox-caddy.log
        fi
    else
        echo -e "${YELLOW}! 未安装 Caddy，跳过站点块${PLAIN}"
    fi

    systemctl restart xray 2>/dev/null && echo -e "${GREEN}✓ Xray 已重启${PLAIN}" \
        || echo -e "${RED}✗ Xray 重启失败，看 journalctl -u xray${PLAIN}"
}

# ---------------------------------------------------------------- 订阅
gen_mihomo() {
    load_env || return 1
    echo "proxies:"
    local name transport port path enc_srv enc_cli
    while IFS='|' read -r name transport port path enc_srv enc_cli; do
        [[ -z "${name:-}" ]] && continue
        echo "  - name: \"${name}\""
        echo "    type: vless"
        echo "    server: ${DOMAIN}"
        echo "    port: ${FRONT_PORT}"
        echo "    uuid: ${UUID}"
        echo "    network: ${transport}"
        echo "    udp: true"
        echo "    tls: true"
        echo "    servername: ${DOMAIN}"
        echo "    client-fingerprint: chrome"
        [[ "${enc_cli}" != "none" ]] && echo "    encryption: \"${enc_cli}\""
        if [[ "$transport" == "xhttp" ]]; then
            echo "    xhttp-opts:"
            echo "      path: \"${path}\""
            echo "      host: ${DOMAIN}"
        else
            echo "    ws-opts:"
            echo "      path: \"${path}\""
            echo "      headers:"
            echo "        Host: ${DOMAIN}"
        fi
    done < "$NODES_FILE"
    echo ""
    echo "proxy-groups:"
    echo "  - name: PROXY"
    echo "    type: select"
    echo -n "    proxies: ["
    local first=1
    while IFS='|' read -r name _; do
        [[ -z "${name:-}" ]] && continue
        [[ $first -eq 1 ]] || echo -n ", "
        first=0
        echo -n "\"${name}\""
    done < "$NODES_FILE"
    echo "]"
    echo ""
    echo "rules:"
    echo "  - MATCH,PROXY"
}

gen_singbox() {
    load_env || return 1
    local skipped=""
    echo "outbounds:"
    local name transport port path enc_srv enc_cli
    while IFS='|' read -r name transport port path enc_srv enc_cli; do
        [[ -z "${name:-}" ]] && continue
        if [[ "$transport" != "ws" ]]; then
            skipped+="${name}(XHTTP) "; continue
        fi
        if [[ "${enc_cli}" != "none" ]]; then
            skipped+="${name}(加密) "; continue
        fi
        echo "  - type: vless"
        echo "    tag: \"${name}\""
        echo "    server: ${DOMAIN}"
        echo "    server_port: ${FRONT_PORT}"
        echo "    uuid: ${UUID}"
        echo "    tls:"
        echo "      enabled: true"
        echo "      server_name: ${DOMAIN}"
        echo "    transport:"
        echo "      type: ws"
        echo "      path: \"${path}\""
        echo "      headers:"
        echo "        Host: ${DOMAIN}"
    done < "$NODES_FILE"
    [[ -n "$skipped" ]] && echo "# 已跳过 sing-box 不支持的节点: ${skipped}"
}

gen_links() {
    load_env || return 1
    local name transport port path enc_srv enc_cli enc
    while IFS='|' read -r name transport port path enc_srv enc_cli; do
        [[ -z "${name:-}" ]] && continue
        enc="${enc_cli}"
        [[ "$enc" == "none" ]] && enc="none"
        local enc_enc path_enc
        enc_enc=$(printf '%s' "$enc" | sed 's/:/%3A/g; s#/#%2F#g; s/+/%2B/g; s/=/%3D/g')
        path_enc=$(printf '%s' "$path" | sed 's#/#%2F#g')
        echo "vless://${UUID}@${DOMAIN}:${FRONT_PORT}?encryption=${enc_enc}&security=tls&sni=${DOMAIN}&fp=chrome&type=${transport}&path=${path_enc}&host=${DOMAIN}#${name}"
    done < "$NODES_FILE"
}

write_sub_files() {
    load_env || return 1
    mkdir -p "${WEB_DIR}/${SUB_TOKEN}"
    gen_mihomo > "${WEB_DIR}/${SUB_TOKEN}/mihomo.yaml"
    gen_singbox > "${WEB_DIR}/${SUB_TOKEN}/singbox.yaml"
    gen_links > "${WEB_DIR}/${SUB_TOKEN}/links.txt"
    echo -e "${GREEN}✓ 已写入 ${WEB_DIR}/${SUB_TOKEN}/${PLAIN}"
}

# ---------------------------------------------------------------- 节点操作
add_node() {
    load_env || return 1
    local transport="$1"
    local default_enc="none"
    [[ "$transport" == "xhttp" ]] && default_enc="x25519"

    echo ""
    local name
    read -r -p "节点名称（如 SL-${transport^^}）: " name
    [[ -z "$name" ]] && { echo -e "${RED}名称不能为空${PLAIN}"; pause; return 1; }
    if [[ -f "$NODES_FILE" ]] && cut -d'|' -f1 "$NODES_FILE" | grep -qx "$name"; then
        echo -e "${RED}节点名已存在${PLAIN}"; pause; return 1
    fi

    local enc_kind
    read -r -p "VLESS 加密 [none/x25519/mlkem]（默认 ${default_enc}）: " enc_kind
    enc_kind="${enc_kind:-$default_enc}"
    case "$enc_kind" in
        none|x25519|mlkem) ;;
        *) echo -e "${RED}无效选择，用默认 ${default_enc}${PLAIN}"; enc_kind="$default_enc" ;;
    esac

    local port=10000
    if [[ -f "$NODES_FILE" ]]; then
        local last
        last=$(cut -d'|' -f3 "$NODES_FILE" | sort -n | tail -n1)
        [[ -n "$last" ]] && port=$((last + 1))
    fi

    local path
    path=$(rand_path)
    local pair enc_srv enc_cli
    pair=$(gen_enc "$enc_kind")
    enc_srv="${pair%%|*}"
    enc_cli="${pair##*|}"

    mkdir -p "$CONF_DIR"
    printf '%s|%s|%s|%s|%s|%s\n' "$name" "$transport" "$port" "$path" "$enc_srv" "$enc_cli" >> "$NODES_FILE"
    chmod 600 "$NODES_FILE"

    echo ""
    echo -e "${GREEN}✓ 已添加 ${name}${PLAIN}"
    echo "  传输  ${transport}"
    echo "  端口  127.0.0.1:${port}"
    echo "  路径  ${path}"
    echo "  加密  ${enc_kind}"
    echo ""
    echo -e "${YELLOW}执行「应用配置」后生效${PLAIN}"
    pause
}

del_node() {
    load_env || return 1
    [[ -f "$NODES_FILE" ]] || { echo -e "${YELLOW}没有节点${PLAIN}"; pause; return; }
    list_nodes
    local name
    read -r -p "要删除的节点名: " name
    [[ -z "$name" ]] && return
    if grep -q "^${name}|" "$NODES_FILE"; then
        grep -v "^${name}|" "$NODES_FILE" > "${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "$NODES_FILE"
        echo -e "${GREEN}✓ 已删除 ${name}${PLAIN}"
    else
        echo -e "${RED}没有这个节点${PLAIN}"
    fi
    pause
}

list_nodes() {
    load_env || return 1
    if [[ ! -f "$NODES_FILE" ]] || [[ ! -s "$NODES_FILE" ]]; then
        echo -e "${YELLOW}还没有节点${PLAIN}"
        return
    fi
    printf "%-16s %-6s %-7s %-22s %s\n" "名称" "传输" "端口" "路径" "加密"
    local name transport port path enc_srv enc_cli kind
    while IFS='|' read -r name transport port path enc_srv enc_cli; do
        [[ -z "${name:-}" ]] && continue
        kind="off"
        [[ "$enc_srv" != "none" ]] && kind="on"
        printf "%-16s %-6s %-7s %-22s %s\n" "$name" "$transport" "$port" "$path" "$kind"
    done < "$NODES_FILE"
}

# ---------------------------------------------------------------- 安装
install_xray() {
    if command -v xray >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 已安装 Xray $(xray_ver)${PLAIN}"
        return 0
    fi
    echo -e "${CYAN}正在安装 Xray...${PLAIN}"
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/raybox-xray-install.log 2>&1
    if command -v xray >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Xray $(xray_ver) 安装完成${PLAIN}"
    else
        echo -e "${RED}✗ 安装失败，见 /tmp/raybox-xray-install.log${PLAIN}"
        return 1
    fi
}

install_wizard() {
    clear
    echo -e "${GRAY}====================================================${PLAIN}"
    echo -e "${BOLD}              Ray-Box 安装向导${PLAIN}"
    echo -e "${GRAY}====================================================${PLAIN}"
    echo ""
    echo "  Xray 只监听 127.0.0.1，由 Caddy 在 443 上按路径反代。"
    echo "  所以这台机器需要已经有一个 Caddy 托管的站点。"
    echo ""

    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${YELLOW}! 未检测到 Caddy。装完 Ray-Box 后需要自行配置站点。${PLAIN}"
        echo ""
    fi

    local domain site port
    read -r -p "域名（必须已解析到本机）: " domain
    [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空${PLAIN}"; return 1; }

    read -r -p "站点根目录 [/var/www/${domain}]: " site
    site="${site:-/var/www/${domain}}"

    read -r -p "对外端口 [443]: " port
    port="${port:-443}"

    DOMAIN="$domain"
    SITE_ROOT="$site"
    FRONT_PORT="$port"
    UUID=$(xray uuid)
    SUB_TOKEN=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
    save_env
    : > "$NODES_FILE"
    chmod 600 "$NODES_FILE"

    install_xray || { pause; return 1; }

    # 自安装：拷到固定位置并建立 raybox 命令
    mkdir -p /usr/local/share/ray-box
    if [[ -f "${BASH_SOURCE[0]}" ]] && [[ "${BASH_SOURCE[0]}" != "/usr/local/share/ray-box/raybox.sh" ]]; then
        cp "${BASH_SOURCE[0]}" /usr/local/share/ray-box/raybox.sh
        chmod +x /usr/local/share/ray-box/raybox.sh
        ln -sf /usr/local/share/ray-box/raybox.sh /usr/local/bin/raybox
        echo -e "${GREEN}✓ 已安装命令 raybox${PLAIN}"
    fi

    echo ""
    echo -e "${GREEN}✓ 初始化完成${PLAIN}"
    echo "  域名  ${DOMAIN}"
    echo "  站点  ${SITE_ROOT}"
    echo "  端口  ${FRONT_PORT}"
    echo ""
    echo "下一步：菜单 1 添加节点，然后菜单 3 应用配置。"
    pause
}

# ---------------------------------------------------------------- 菜单
menu_nodes() {
    while true; do
        [ -t 1 ] && clear
        echo -e "${GRAY}====================== 节点管理 ======================${PLAIN}"
        list_nodes
        echo -e "${GRAY}======================================================${PLAIN}"
        echo " 1. 添加 XHTTP 节点（伪装最好，仅 mihomo 系）"
        echo " 2. 添加 WS 节点（mihomo + sing-box）"
        echo " 3. 删除节点"
        echo " 4. 应用配置（重启 Xray + 重载 Caddy）"
        echo " 0. 返回主菜单"
        echo -e "${GRAY}======================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-4]: " opt || opt="0"
        case "$opt" in
            1) add_node xhttp ;;
            2) add_node ws ;;
            3) del_node ;;
            4) apply_all; pause ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_sub() {
    load_env || { echo -e "${RED}尚未初始化${PLAIN}"; pause; return; }
    while true; do
        [ -t 1 ] && clear
        echo -e "${GRAY}====================== 订阅与链接 ====================${PLAIN}"
        echo " 1. 显示 mihomo / ClashX Meta 订阅"
        echo " 2. 显示 sing-box 订阅（自动跳过 XHTTP 与加密节点）"
        echo " 3. 显示 vless:// 链接"
        echo " 4. 写入订阅文件到 ${WEB_DIR}/${SUB_TOKEN}/"
        echo " 0. 返回主菜单"
        echo -e "${GRAY}======================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-4]: " opt || opt="0"
        case "$opt" in
            1) echo ""; gen_mihomo; echo ""; pause ;;
            2) echo ""; gen_singbox; echo ""; pause ;;
            3) echo ""; gen_links; echo ""; pause ;;
            4) write_sub_files; pause ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu_core() {
    while true; do
        [ -t 1 ] && clear
        echo -e "${GRAY}====================== 内核管理 ======================${PLAIN}"
        echo " 1. 重启 Xray"
        echo " 2. 检查并更新 Xray 内核"
        echo " 3. 查看最近 40 行日志"
        echo " 0. 返回主菜单"
        echo -e "${GRAY}======================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-3]: " opt || opt="0"
        case "$opt" in
            1)
                systemctl restart xray 2>/dev/null \
                    && echo -e "${GREEN}✓ Xray 已重启${PLAIN}" \
                    || echo -e "${RED}重启失败${PLAIN}"
                pause ;;
            2)
                bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/tmp/raybox-xray-update.log 2>&1
                echo -e "${GREEN}✓ 当前版本 $(xray_ver)${PLAIN}"
                systemctl restart xray 2>/dev/null || true
                pause ;;
            3)
                echo ""
                journalctl -u xray -o cat -n 40 --no-pager || true
                echo ""
                pause ;;
            0) break ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

menu() {
    while true; do
        [ -t 1 ] && clear
        load_env || true

        local ip xray_st caddy_st nodes
        ip=$(curl -s4m3 https://icanhazip.com 2>/dev/null || echo "检测中...")
        nodes=$(node_count)

        if command -v xray >/dev/null 2>&1; then
            if is_active xray; then
                xray_st="${GREEN}运行中 (v$(xray_ver))${PLAIN}"
            else
                xray_st="${RED}已停止 (v$(xray_ver))${PLAIN}"
            fi
        else
            xray_st="${RED}未安装${PLAIN}"
        fi

        if command -v caddy >/dev/null 2>&1; then
            if is_active caddy; then
                caddy_st="${GREEN}运行中${PLAIN}"
            else
                caddy_st="${RED}已停止${PLAIN}"
            fi
        else
            caddy_st="${RED}未安装${PLAIN}"
        fi

        echo -e "${GRAY}====================================================${PLAIN}"
        echo -e "${BOLD}                  Ray-Box 控制台${PLAIN}"
        echo -e "${GRAY}====================================================${PLAIN}"
        echo -e " 公网地址: ${ip}"
        if installed; then
            echo -e " 域名    : ${DOMAIN}:${FRONT_PORT}"
            echo -e " 站点    : ${SITE_ROOT}"
        else
            echo -e " 域名    : ${YELLOW}未配置${PLAIN}"
        fi
        echo -e " Xray    : ${xray_st}"
        echo -e " Caddy   : ${caddy_st}"
        echo -e " 节点数  : ${nodes}"
        echo -e "${GRAY}====================================================${PLAIN}"
        echo " 1. 节点管理"
        echo " 2. 订阅与链接"
        echo " 3. 应用配置（写入 Xray + Caddy 并重启）"
        echo " 4. 内核管理"
        echo " 5. 更新脚本"
        echo " 6. 卸载"
        echo " 0. 退出"
        echo -e "${GRAY}====================================================${PLAIN}"
        local opt=""
        read -r -p "请输入选项 [0-6]: " opt || opt="0"
        case "$opt" in
            1) menu_nodes ;;
            2) menu_sub ;;
            3) apply_all; pause ;;
            4) menu_core ;;
            5)
                curl -fsSL "$SCRIPT_URL" -o /tmp/raybox.new 2>/dev/null \
                    && bash -n /tmp/raybox.new 2>/dev/null \
                    && cp /tmp/raybox.new "${BASH_SOURCE[0]}" \
                    && echo -e "${GREEN}✓ 已更新，重新运行生效${PLAIN}" \
                    || echo -e "${RED}更新失败${PLAIN}"
                pause ;;
            6)
                local c
                read -r -p "确认卸载 Ray-Box？配置会删除，Xray 与 Caddy 保留 [y/N]: " c
                if [[ "$c" == "y" || "$c" == "Y" ]]; then
                    rm -f "$CADDY_SITE" "$XRAY_CONF"
                    systemctl stop xray 2>/dev/null || true
                    systemctl reload caddy 2>/dev/null || true
                    rm -rf "$CONF_DIR"
                    echo -e "${GREEN}✓ 已卸载${PLAIN}"
                    exit 0
                fi ;;
            0) echo -e "${GREEN}已退出。输入 raybox 可重新打开面板。${PLAIN}"; exit 0 ;;
            *) echo -e "${RED}无效选项${PLAIN}"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------- 入口
OS_NAME=$(require_os) || exit 1
export OS_NAME

case "${1:-}" in
    install|reinstall) install_wizard ;;
    "")
        if ! installed; then
            echo -e "${YELLOW}未检测到已安装的 Ray-Box，进入安装向导...${PLAIN}"
            sleep 1
            install_wizard
        fi
        menu ;;
    *) menu ;;
esac
