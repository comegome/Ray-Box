# Ray-Box

基于 **Xray 核心**的 VLESS 节点管理面板，仿 [Simple-Box](https://github.com/comegome/Simple-Box) 的交互式设计。

节点藏在一个真实的 HTTPS 站点后面：Caddy 占 443 提供站点与证书，按路径把流量反代到 loopback 上的 Xray。

## 与已有站点共存（attach 模式）

机器上已经有 Caddy 站点（例如站点和代理共用同一个域名）时，Ray-Box **不再生成整块站点配置**，而是：

```
/etc/caddy/snippets/raybox.caddy     只含 @rbN path + reverse_proxy 的 handler
/etc/caddy/sites/<你的站点>.caddy     只多一行 import /etc/caddy/snippets/raybox.caddy  # raybox-attach
```

站点自己的 `tls`、`root`、`try_files`、`header`、跳转全部保持原样。注入与移除由 `raybox-attach.py` 完成：

```bash
# 注入（幂等；找不到域名站点会以退出码 2 拒绝，括号不配平以 3 拒绝）
sudo python3 /usr/local/share/raybox/raybox-attach.py attach \
    --caddy-dir /etc/caddy --domain example.com \
    --snippet /etc/caddy/snippets/raybox.caddy --backup --manifest /etc/raybox/attach.json

# 移除（逐字节还原）
sudo python3 /usr/local/share/raybox/raybox-attach.py detach \
    --caddy-dir /etc/caddy --domain example.com
```

不管哪种模式，改完都必须 `caddy validate` 再 reload；顺序是"先写 snippet 再插 import"，卸载相反。

### 测试

```bash
bash tests/test-attach.sh   # 18 项：插入位置、幂等、卸载还原、拒绝路径
bash tests/test-e2e.sh      # 真实 Caddy + 假 Xray：注入后路径可达、卸载后回退
```

`test-e2e.sh` 只用 `127.0.0.1` 高位端口（18443/12019/11000）和 `/tmp` 目录，不碰系统 Caddy。

## 两种传输

```
XHTTP   VLESS + XHTTP + TLS   伪装最好，只有 mihomo / ClashX Meta 系能用
WS      VLESS + WS   + TLS    mihomo 和 sing-box 都能用
```

两种都可以叠加 **VLESS Encryption**（后量子密钥交换 + 长度填充）：

```
none      不加密，靠 TLS 保护（WS 节点默认，为了兼容 sing-box）
x25519    认证用 X25519，握手仍是后量子安全，参数短（XHTTP 节点默认）
mlkem     认证用 ML-KEM-768，全后量子，参数约 1800 字符
```

## 架构

```
443  Caddy（真实证书，站点 + 按路径反代）
     ├── /assets/<hex>  → 127.0.0.1:10000  (Xray XHTTP)
     ├── /assets/<hex>  → 127.0.0.1:10001  (Xray WS)
     └── 其他            → /var/www/<site>
```

Xray 永远只监听 loopback。**站点挂了节点就挂**——这是伪装换来的代价，不是缺陷。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/comegome/Ray-Box/main/raybox.sh -o /tmp/raybox.sh
sudo bash /tmp/raybox.sh
```

首次运行进安装向导：填域名、站点根目录、对外端口，脚本自动装 Xray、写 `/etc/raybox/`、建立 `raybox` 命令。

之后随时输入 `raybox` 打开面板。

## 面板

```
====================================================
                  Ray-Box 控制台
====================================================
 公网地址: 1.2.3.4
 域名    : hwsignal.yuzhaizu.com:443
 站点    : /var/www/hwsignal
 Xray    : 运行中 (v26.11.9)
 Caddy   : 运行中
 节点数  : 2
====================================================
 1. 节点管理
 2. 订阅与链接
 3. 应用配置（写入 Xray + Caddy 并重启）
 4. 内核管理
 5. 更新脚本
 6. 卸载
 0. 退出
```

节点管理里添加节点时只需要填名字，端口、路径、加密参数自动生成：

```
 1. 添加 XHTTP 节点（伪装最好，仅 mihomo 系）
 2. 添加 WS 节点（mihomo + sing-box）
 3. 删除节点
 4. 应用配置（重启 Xray + 重载 Caddy）
```

订阅菜单输出三种格式，sing-box 会自动跳过 XHTTP 和加密节点并注明原因。

`config.yaml` 是**完整配置**：`template.yaml`（TUN / DNS / sniffer / 分流规则）+ 自动注入的节点直连规则 + `proxies` + `proxy-groups`。策略组固定为：

```
📌节点选择   select    ♻️自动选择 / 各节点
♻️自动选择   url-test  全部节点，300s 间隔，50ms 容差
```

`provider.yaml` 只有 `proxies`，给需要 provider 的场景用。

## 文件

```
/etc/raybox/env.conf        域名、站点、UUID、订阅 token（600）
/etc/raybox/nodes.conf      节点表：名称|传输|端口|路径|服务端密钥|客户端密钥（600）
/usr/local/etc/xray/config.json
/etc/caddy/sites/raybox.caddy      443 站点 + 节点反代
/etc/caddy/sites/raybox-sub.caddy  订阅服务（默认 8444）
/etc/raybox/web/<token>/           config.yaml / provider.yaml / singbox.yaml / links.txt
/etc/raybox/template.yaml          完整配置模板（缺失时从仓库拉取）
/usr/local/share/ray-box/raybox.sh  → /usr/local/bin/raybox
```

订阅地址：`https://<域名>:8444/<token>/config.yaml`

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
XHTTP 是长连接的流式 HTTP 响应，gzip 会把它缓冲住，客户端表现为 `context deadline exceeded`，而 WS 完全正常。`encode` 只能放在静态文件的 `handle` 里，不能放站点顶层。脚本生成的配置已经这么处理——这是第一版实测踩出来的。

**3. XHTTP 只有 mihomo 系能用。**
sing-box 不支持 xhttp 传输。订阅要分流：xhttp 节点只给 mihomo，ws 节点两边都给。`sing-box` 订阅会自动跳过 xhttp 节点并注明。

**4. 路径会被隧道独占。**
`handle @rb0` 优先于 `file_server`，站点里如果真有 `/assets/<hex>` 这个文件就访问不到了。默认路径带 8 位随机 hex，撞上的概率可以忽略；但不要手改成 `/assets/logo.png` 这种。

**5. 443 只能有一个进程。**
Ray-Box 假设 Caddy 占 443。机器上已经有 sing-box / nginx 占着的话必须先挪走，否则 Caddy 起不来，而且 reload 是**卡住**不是立刻报错。

**6. 端口要避开 UDP。**
Caddy 绑端口是 TCP+UDP 一起绑。测试时把站点块放到 8443，和 sing-box 的 Hy2（UDP 8443）撞了，Caddy 直接起不来。选端口先 `ss -lnup` 看一眼。

**7. 加密参数必须成对。**
`xray vlessenc` 一次输出服务端 `decryption` 和客户端 `encryption`，改一个必须改另一个。脚本把成对参数存在 nodes.conf 里，订阅输出的就是配对的另一半。

**8. mlkem 参数极长。**
约 1800 字符，订阅链接和二维码会很长，部分客户端 UI 会截断。握手在任何模式下都是后量子安全的，只有「认证」这一步分经典/后量子——所以默认建议 x25519。

**9. 不要设 flow。**
`xtls-rprx-vision` 只对 TCP+TLS 或 VLESS Encryption 有效，配在 XHTTP/WS 上会失败。脚本不生成 flow 字段。

**10. 站点与节点耦合。**
Caddy 重启、证书续期失败、站点目录被删，节点全部不可用。监控要盯站点，不只是盯节点端口。

**11. Caddy reload 碰到 UDP 监听会卡死。**
站点块从「只有 TCP」变成「新增 HTTP/3（UDP）」时，`systemctl reload caddy` 会报 `listen udp :8444: bind: address already in use`，单元卡在 `reloading`，旧配置继续跑。必须 `systemctl restart caddy`。脚本在 reload 后检查状态，卡住会自动改成重启。

**12. `tun.stack` 不要写 `mips`。**
`mips` 只在 mihomo ≥1.19.34 才被接受，旧内核直接报 `invalid tun stack`，客户端只显示一句 `Test failed, status 1`，看不出是哪个字段。模板默认用 `gvisor`，实测 1.19.10 / 1.19.20 / 1.19.34 都能通过。

## 和 Simple-Box 的差异

```
核心      Xray            sing-box
入口      反代（Caddy）    核心自己听 443
伪装      真站点 + 真证书   REALITY 借用外部站
耦合      站点挂=节点挂     节点独立
客户端    mihomo 优先      mihomo + sing-box
```
