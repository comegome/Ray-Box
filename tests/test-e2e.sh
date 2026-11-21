#!/bin/bash
# 端到端：真实 Caddy + 假 Xray，验证 import 路由生效/卸载后回退
set -uo pipefail
T=/tmp/raybox-test
ATTACH=~/projects/raybox/raybox-attach.py
pkill -f 'caddy run --config' 2>/dev/null || true
pkill -f 'http.server 11000' 2>/dev/null || true
sleep 1

rm -rf $T/sites $T/www $T/data && mkdir -p $T/sites $T/www $T/data $T/fakex
echo '<h1>real site</h1>' > $T/www/index.html
mkdir -p $T/fakex/assets && echo 'FAKE-XRAY-OK' > $T/fakex/assets/abc

cat > $T/Caddyfile <<'EOF'
{
	admin 127.0.0.1:12019
	auto_https off
}
import sites/*.caddy
EOF

cat > $T/sites/site.caddy <<'EOF'
http://127.0.0.1:18443 {
	root * /tmp/raybox-test/www
	encode gzip
	try_files {path} {path}.html {path}/index.html
	file_server
	handle_errors {
		rewrite * /404.html
		file_server
	}
}
EOF
echo 'not found' > $T/www/404.html

cat > $T/snippet.caddy <<'EOF'
@rb0 path /assets/abc /assets/abc/*
handle @rb0 {
	reverse_proxy 127.0.0.1:11000
}
EOF

export XDG_DATA_HOME=$T/data XDG_CONFIG_HOME=$T/data
$T/bin/caddy validate --config $T/Caddyfile --adapter caddyfile >/tmp/rb-validate.log 2>&1 || { echo "初始校验失败"; tail -3 /tmp/rb-validate.log; exit 1; }
$T/bin/caddy run --config $T/Caddyfile --adapter caddyfile >/tmp/rb-caddy.log 2>&1 &
sleep 3
python3 -m http.server 11000 --directory $T/fakex >/tmp/rb-fake.log 2>&1 &
sleep 1

echo "== 注入前 =="
echo -n "/            : "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18443/
echo -n "/assets/abc  : "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18443/assets/abc

python3 $ATTACH attach --caddy-dir $T --domain 127.0.0.1 --snippet $T/snippet.caddy
$T/bin/caddy validate --config $T/Caddyfile --adapter caddyfile >/tmp/rb-validate2.log 2>&1 || { echo "注入后校验失败"; tail -5 /tmp/rb-validate2.log; exit 1; }
$T/bin/caddy reload --config $T/Caddyfile --adapter caddyfile --address 127.0.0.1:12019 >/dev/null 2>&1
sleep 1

echo "== 注入后 =="
echo -n "/            : "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18443/
echo -n "/assets/abc  : "; curl -s -w " [%{http_code}]\n" http://127.0.0.1:18443/assets/abc
echo -n "/assets/abc  : "; curl -s -w " [%{http_code}]\n" http://127.0.0.1:18443/assets/abc

python3 $ATTACH detach --caddy-dir $T --domain 127.0.0.1
$T/bin/caddy reload --config $T/Caddyfile --adapter caddyfile --address 127.0.0.1:12019 >/dev/null 2>&1
sleep 1
echo "== 卸载后 =="
echo -n "/            : "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18443/
echo -n "/assets/abc  : "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18443/assets/abc

pkill -f 'caddy run --config' 2>/dev/null || true
pkill -f 'http.server 11000' 2>/dev/null || true
echo "== 站点文件行数 =="
wc -l < $T/sites/site.caddy
