#!/usr/bin/env bash
# Ray-Box 回归测试（Xray 翻转版）
# 用法: sudo bash tests/test-regression.sh [脚本路径]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-${HERE}/../raybox.sh}"
[[ -f "$TARGET" ]] || { echo "找不到脚本: $TARGET"; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok()  { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  \033[31m✗\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

group "1. 语法"
if bash -n "$TARGET" 2>/dev/null; then ok "bash -n 通过"; else bad "bash -n 失败" "$(bash -n "$TARGET" 2>&1 | head -3)"; fi
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error "$TARGET" >/dev/null 2>&1; then ok "shellcheck(error) 通过"; else bad "shellcheck 发现问题" "$(shellcheck -S error "$TARGET" 2>&1 | head -10)"; fi
else
    printf '  \033[33m-\033[0m shellcheck 未安装，跳过\n'
fi

# 取到 EUID 守卫之前的部分，避免 source 时进菜单
GUARD=$(grep -n 'if \[\[ \$EUID -ne 0 \]\]' "$TARGET" | head -1 | cut -d: -f1)
[[ -n "$GUARD" ]] || { echo "找不到入口守卫，无法加载函数"; exit 1; }
LIB=$(mktemp /tmp/rb-lib.XXXXXX)
head -n $((GUARD-1)) "$TARGET" > "$LIB"

group "2. 函数与模式"
# shellcheck disable=SC1090
source "$LIB"
for fn in load_env save_env render_xray render_site render_sub gen_proxies gen_singbox gen_links apply_all self_check wait_service_active gen_reality_keys; do
    if declare -F "$fn" >/dev/null 2>&1; then ok "函数存在: $fn"; else bad "缺少函数: $fn"; fi
done

group "3. 拓扑不变量（翻转）"
if grep -q '"listen": "0.0.0.0"' "$TARGET" && grep -q '"port": ${VL_PORT}' "$TARGET"; then ok "Reality 监听 0.0.0.0:VL_PORT"; else bad "未按翻转方式监听 443"; fi
if grep -q 'dest": "127.0.0.1:${FLIP_PORT}"' "$TARGET"; then ok "回落指向 loopback:FLIP_PORT"; else bad "回落目标不是 loopback"; fi
if grep -qE 'bind 127\.0\.0\.1' "$TARGET"; then ok "站点 bind 127.0.0.1"; else bad "站点未限制在 loopback"; fi
if ! grep -qiE 'xhttp|ws-opts|raybox-attach|@rb[0-9]' "$TARGET"; then ok "已无 WS/XHTTP/attach 残留"; else bad "仍含旧形态代码" "$(grep -niE 'xhttp|ws-opts|raybox-attach|@rb[0-9]' "$TARGET" | head -3)"; fi
if grep -q 'support-x25519mlkem768: true' "$TARGET"; then ok "订阅带 mlkem 兼容开关"; else bad "缺少 support-x25519mlkem768（mihomo 会握手失败）"; fi

group "4. 配置生成（真跑）"
# 有 xray 时用真密钥，否则 xray -test 会因为占位私钥非法而失败
RP="PRIVKEY_FOR_TEST"; RQ="PUBKEY_FOR_TEST"
if command -v xray >/dev/null 2>&1; then
    KO=$(xray x25519 2>/dev/null)
    RP=$(printf '%s\n' "$KO" | awk -F': ' '/^PrivateKey:/{print $2; exit}')
    RQ=$(printf '%s\n' "$KO" | grep -oP 'Password \(PublicKey\): \K\S+' || true)
fi
export DOMAIN="test.example.com" SITE_ROOT="/var/www/test" VL_PORT=443 VL_SNI="test.example.com" \
       FLIP_PORT=9443 SUB_DOMAIN="sub.example.net" SUB_PORT=8444 NODE_NAME="TEST-Reality" \
       UUID="11111111-2222-3333-4444-555555555555" REALITY_PRIV="$RP" \
       REALITY_PUB="$RQ" REALITY_SID="0123456789abcdef" SUB_TOKEN="tok123" \
       TLS_CERT="" TLS_KEY="" DIRECT_SUFFIXES=""
OUT=$(mktemp --suffix=.json); render_xray "$OUT"
if python3 -c "import json,sys; json.load(open('$OUT'))" 2>/dev/null; then ok "render_xray 是合法 JSON"; else bad "render_xray 输出非法"; fi
if python3 - "$OUT" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
ib=c["inbounds"][0]; rs=ib["streamSettings"]["realitySettings"]
assert ib["streamSettings"]["security"]=="reality"
assert rs["dest"]=="127.0.0.1:9443"
assert rs["serverNames"]==["test.example.com"]
assert rs["shortIds"]==["0123456789abcdef"]
assert ib["settings"]["clients"][0]["flow"]=="xtls-rprx-vision"
PY
then ok "Reality 关键字段正确"; else bad "Reality 关键字段错误"; fi
if command -v xray >/dev/null 2>&1; then
    if XOUT=$(xray run -test -c "$OUT" 2>&1); then ok "xray -test 通过"; else bad "xray -test 失败" "$(printf '%s' "$XOUT" | tail -3)"; fi
else
    printf '  \033[33m-\033[0m 未安装 xray，跳过 -test\n'
fi

group "5. 站点与订阅块"
SITE=$(mktemp); render_site > "$SITE"
grep -q "https://test.example.com:9443" "$SITE" && ok "站点地址用域名:9443" || bad "站点地址不正确"
grep -q "root \* /var/www/test" "$SITE" && ok "站点根目录正确" || bad "站点根目录错误"
grep -q "http://test.example.com" "$SITE" && ok "保留 80 端口跳转（ACME 用）" || bad "缺少 80 端口块"
SUB=$(mktemp); render_sub > "$SUB"
grep -q "sub.example.net:8444" "$SUB" && ok "订阅块用 SUB_DOMAIN" || bad "订阅块未用 SUB_DOMAIN"
grep -q "respond 404" "$SUB" && ok "订阅块兜底 404" || bad "订阅块缺少兜底"

group "6. 订阅内容"
P=$(gen_proxies); L=$(gen_links); S=$(gen_singbox)
echo "$P" | grep -q "reality-opts:" && ok "mihomo 片段含 reality-opts" || bad "mihomo 片段缺 reality-opts"
echo "$P" | grep -q "support-x25519mlkem768: true" && ok "mihomo 片段含 mlkem" || bad "mihomo 片段缺 mlkem"
echo "$P" | grep -q "flow: xtls-rprx-vision" && ok "mihomo 片段含 Vision flow" || bad "缺 flow"
echo "$L" | grep -q "security=reality" && echo "$L" | grep -q "pbk=${RQ}" && ok "链接参数完整" || bad "链接参数不完整"
echo "$L" | grep -q "@test.example.com:443" && ok "链接指向入口域名" || bad "链接 server 不正确"
echo "$S" | grep -q "reality:" && ok "sing-box 片段含 reality" || bad "sing-box 片段缺 reality"

group "7. 健壮性"
if grep -q 'wait_service_active caddy 10' "$TARGET" && grep -q 'wait_service_active xray 10' "$TARGET"; then ok "reload/restart 后轮询 active"; else bad "缺少服务轮询"; fi
if grep -q 'xray run -test' "$TARGET"; then ok "写盘前做 xray -test"; else bad "缺少写盘前校验"; fi
if grep -q 'chmod 600 "$ENV_FILE"' "$TARGET"; then ok "env.conf 权限 600"; else bad "env.conf 权限未收紧"; fi
if grep -q 'REALITY_SID=$(openssl rand -hex 8)' "$TARGET"; then ok "shortId 随机 8 字节"; else bad "shortId 未随机生成"; fi

rm -f "$LIB" "$OUT" "$SITE" "$SUB" 2>/dev/null
printf '\n================ 汇总 ================\n'
printf '通过: %d   失败: %d   总计: %d\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
if (( FAIL > 0 )); then printf '失败项:\n'; printf ' - %s\n' "${FAILED[@]}"; exit 1; fi
echo "全部通过"
