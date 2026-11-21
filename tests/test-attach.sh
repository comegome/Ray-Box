#!/usr/bin/env bash
# Ray-Box attach 模式的离线回归测试（不碰任何生产配置）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ATTACH="$HERE/../raybox-attach.py"
WORK=$(mktemp -d)
PASS=0; FAIL=0
trap 'rm -rf "$WORK"' EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

run_case() { # 名称 fixture 域名
    local name="$1" fx="$2" dom="$3"
    local dir="$WORK/$name"
    mkdir -p "$dir/sites"
    cp "$fx" "$dir/sites/site.caddy"
    local file="$dir/sites/site.caddy"
    local snippet="$dir/snippet.caddy"
    printf '@rb0 path /assets/abc\nhandle @rb0 {\n\treverse_proxy 127.0.0.1:11000\n}\n' > "$snippet"

    echo "== $name =="
    local orig after1 after2 rc
    orig=$(sha256sum "$file" | cut -d' ' -f1)

    python3 "$ATTACH" attach --caddy-dir "$dir" --domain "$dom" --snippet "$snippet" >/dev/null 2>&1
    rc=$?
    check "attach 退出码 0" [ "$rc" -eq 0 ]
    after1=$(sha256sum "$file" | cut -d' ' -f1)
    check "文件发生变化" [ "$orig" != "$after1" ]
    check "只多一行" [ "$(diff "$fx" "$file" | grep -c '^>')" -eq 1 ]
    check "有且只有一个标记行" [ "$(grep -c 'raybox-attach' "$file")" -eq 1 ]

    local imp tryf
    imp=$(grep -n 'import.*raybox-attach' "$file" | cut -d: -f1 | head -1)
    tryf=$(grep -n 'try_files' "$file" | cut -d: -f1 | head -1)
    check "import 行存在" [ -n "$imp" ]
    if [ -n "$tryf" ] && [ -n "$imp" ]; then
        check "import 在 try_files 之前" [ "$imp" -lt "$tryf" ]
    fi

    python3 "$ATTACH" attach --caddy-dir "$dir" --domain "$dom" --snippet "$snippet" >/dev/null 2>&1
    after2=$(sha256sum "$file" | cut -d' ' -f1)
    check "二次 attach 幂等（字节不变）" [ "$after1" = "$after2" ]

    python3 "$ATTACH" detach --caddy-dir "$dir" --domain "$dom" >/dev/null 2>&1
    check "detach 后与原文件逐字节相同" [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$orig" ]
}

run_case signal "$HERE/fixtures/signal.caddy" agisignal.yuzhaizu.com
run_case nested "$HERE/fixtures/nested.caddy" nested.example.com

echo "== 找不到站点时必须拒绝 =="
mkdir -p "$WORK/miss/sites"
cp "$HERE/fixtures/signal.caddy" "$WORK/miss/sites/site.caddy"
printf 'x\n' > "$WORK/snip.caddy"
python3 "$ATTACH" attach --caddy-dir "$WORK/miss" --domain nope.example.com --snippet "$WORK/snip.caddy" >/dev/null 2>&1
rc=$?
check "退出码 2" [ "$rc" -eq 2 ]
check "文件未被修改" cmp -s "$HERE/fixtures/signal.caddy" "$WORK/miss/sites/site.caddy"

echo "== 不配平的花括号必须拒绝 =="
mkdir -p "$WORK/broken/sites"
printf 'bad.example.com {\n\troot * /x\n' > "$WORK/broken/sites/site.caddy"
python3 "$ATTACH" attach --caddy-dir "$WORK/broken" --domain bad.example.com --snippet "$WORK/snip.caddy" >/dev/null 2>&1
rc=$?
check "退出码 3" [ "$rc" -eq 3 ]

echo "== 同域名订阅站点不能被误伤 =="
mkdir -p "$WORK/sub/sites"
cp "$HERE/fixtures/signal.caddy" "$WORK/sub/sites/signal.caddy"
printf 'agisignal.yuzhaizu.com:8444 {\n\ttls internal\n\troot * /srv/sub\n\tfile_server\n}\n' > "$WORK/sub/sites/raybox-sub.caddy"
printf '@rb0 path /assets/abc\nhandle @rb0 {\n\treverse_proxy 127.0.0.1:11000\n}\n' > "$WORK/sub/snip.caddy"
python3 "$ATTACH" attach --caddy-dir "$WORK/sub" --domain agisignal.yuzhaizu.com --snippet "$WORK/sub/snip.caddy" >/dev/null 2>&1
check "import 注入到 signal.caddy 而不是 raybox-sub.caddy" grep -q raybox-attach "$WORK/sub/sites/signal.caddy"
check "订阅站点保持原样" sh -c "! grep -q raybox-attach '$WORK/sub/sites/raybox-sub.caddy'"
python3 "$ATTACH" detach --caddy-dir "$WORK/sub" --domain agisignal.yuzhaizu.com >/dev/null 2>&1
check "detach 后 signal.caddy 无残留" sh -c "! grep -q raybox-attach '$WORK/sub/sites/signal.caddy'"

echo
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" -eq 0 ]
