# Ray-Box

在 Xray 核心上跑 VLESS 节点，藏在一个真实的 HTTPS 站点后面。

和 simbo（simple-box）思路相同，但核心换成 Xray，并且**不碰 REALITY**——原因见下面的「坑」。

## 两种传输

```
xhttp   VLESS + XHTTP + TLS   伪装最好，只有 mihomo 系客户端能用
ws      VLESS + WS   + TLS    mihomo 和 sing-box 都能用
```

两种都可以叠加 **VLESS Encryption**（后量子密钥交换 + 长度填充）：

```
none      不加密（默认，靠 TLS 保护）
x25519    认证用 X25519，握手仍是后量子安全，参数字符串短
mlkem     认证用 ML-KEM-768，全后量子，参数字符串约 1800 字符
```

## 架构

```
443  Caddy（真实证书，站点 + 反代）
     ├── /assets/<hex>  → 127.0.0.1:10000  (Xray XHTTP)
     ├── /assets/<hex>  → 127.0.0.1:10001  (Xray WS)
     └── 其他            → /var/www/<site>
```

Xray 只监听 loopback，永远不直接面对公网。Caddy 负责证书、站点和路径分流。

**这意味着站点挂了节点就挂。** 这是设计取舍，不是 bug：没有独立于站点的入口，审查者才看不到破绽。

## 前提

```
Xray >= 25.1      需要 vlessenc（VLESS Encryption）和 xhttp
Caddy             443 上要有真实证书的站点
Python 3.9+       只用标准库
```

## 快速开始

```bash
# 1. 初始化：域名 + 站点目录
python3 raybox.py init --domain hwsignal.yuzhaizu.com --site /var/www/hwsignal

# 2. 加节点
python3 raybox.py add-node --transport xhttp --name SL-XHTTP --encryption x25519
python3 raybox.py add-node --transport ws    --name SL-WS    --encryption none

# 3. 生成配置并重启
python3 raybox.py apply

# 4. 看订阅
python3 raybox.py sub --format mihomo
python3 raybox.py sub --format links
python3 raybox.py sub --format singbox
```

状态文件 `/etc/raybox/state.json`（含 UUID、路径、加密参数，权限 600）。
Xray 配置写 `/usr/local/etc/xray/config.json`，Caddy 块写 `/etc/caddy/sites/raybox.caddy`。

## 命令

```
init        初始化：域名、站点目录、UUID、订阅 token
add-node    添加节点（--transport xhttp|ws，--encryption none|x25519|mlkem）
del-node    删除节点
apply       生成 Xray 配置 + Caddy 块，校验后重启
sub         输出订阅（mihomo / singbox / links）
status      查看状态
```

`apply --print-caddy` 只打印 Caddy 块不写入，适合先看再放。

## 实测矩阵（mihomo v1.19.34 + Xray 26.11.9）

```
VLESS + XHTTP + TLS + enc(x25519)   ✓  Singapore
VLESS + WS    + TLS + enc(mlkem)    ✓  Singapore
VLESS + TCP   + REALITY             ✗  REALITY authentication failed
VLESS + XHTTP + REALITY             ✗  同上
```

## 坑

**1. 不能碰 REALITY。**
mihomo 在 REALITY 握手时把客户端版本写死成 1.8.2，Xray ≥ 26.7.11 校验最低客户端版本，直接拒绝。所有传输都一样，不是 XHTTP 独有的问题。mihomo issue #3039 / #3042，官方 wontfix。清空服务端 `minClientVer` / `maxClientVer` 也没用。

**2. Caddy 的 `encode` 会打死 XHTTP。**
XHTTP 是长连接的流式 HTTP 响应，gzip 会把它缓冲住，客户端表现为 `context deadline exceeded`。所以 `encode` 只能放在静态文件的 `handle` 里，不能放在站点顶层。Ray-Box 生成的配置已经这么处理了——这是第一版实测踩出来的。

**3. XHTTP 只有 mihomo 系能用。**
sing-box 不支持 xhttp 传输。订阅要分流：xhttp 节点只给 mihomo，ws 节点两边都给。`sub --format singbox` 会自动跳过 xhttp 节点并在文件头注明。

**4. 路径会被隧道独占。**
`handle @rb0` 优先于 `file_server`，所以站点里如果真有 `/assets/<hex>` 这个文件，它就访问不到了。默认路径带 8 位随机 hex，撞上的概率可以忽略；但不要手改成 `/assets/logo.png` 这种。

**5. 443 只能有一个进程。**
Ray-Box 假设 Caddy 占 443。如果机器上已经有 sing-box / nginx 占着 443，必须先把它们挪走，否则 Caddy 起不来（reload 会卡住，不是立刻报错）。

**6. 端口要避开 UDP。**
Caddy 绑端口时 TCP 和 UDP 一起绑。测试时把站点块放到 8443，和 sing-box 的 Hy2（UDP 8443）撞了，Caddy 直接起不来。选测试端口先 `ss -lnup` 看一眼。

**7. 加密参数必须成对。**
`xray vlessenc` 一次输出服务端 `decryption` 和客户端 `encryption`，改一个必须改另一个。Ray-Box 把成对的参数一起存在 state.json 里，`sub` 输出的就是配对的另一半。

**8. mlkem 参数极长。**
ML-KEM-768 认证的字符串约 1800 字符，订阅链接和二维码会很长，部分客户端 UI 会截断。握手本身在任何模式下都是后量子安全的，只有「认证」这一步分经典/后量子——所以默认建议 x25519。

**9. 不要设 flow。**
`xtls-rprx-vision` 只在 TCP+TLS/REALITY 或 VLESS Encryption 下有效，配在 XHTTP/WS 上会失败。Ray-Box 不生成 flow 字段。

**10. 站点与节点耦合。**
Caddy 重启、证书续期失败、站点目录被删，节点全部不可用。监控要盯站点，不只是盯节点端口。

## 和 simbo 的差异

```
核心      Xray            sing-box
入口      反代（Caddy）    核心自己听 443
伪装      真站点 + 真证书   REALITY 借用外部站
耦合      站点挂=节点挂     节点独立
客户端    mihomo 优先      mihomo + sing-box
```
