# Ray-Box

基于 **Xray** 的 VLESS-Reality 节点管理脚本。拓扑与 [Simple-Box](https://github.com/comegome/Simple-Box) 一致（**443 翻转**），区别只在核心：这里用 Xray，Simple-Box 用 sing-box。

两个脚本并存的意义不是"两种架构"，而是**同一套运维模型下的双内核**：一套排障方法、两种内核、两条独立线路。

## 拓扑

```
443    xray        VLESS-Reality（独占 443）
                    │  未认证的 TLS 原样转发 ↓
9443   caddy       站点（bind 127.0.0.1，真实证书，真实内容）
80     caddy       ACME HTTP-01 + HTTP→HTTPS 跳转
8444   caddy       订阅（域名可与站点分离，默认 SUB_DOMAIN=DOMAIN）
```

探测者看到的：一个正常的 HTTPS 站点，证书与域名完全自洽；Reality 对未通过认证的连接不做任何改写，直接转发给本地站点。

## 安装

```bash
bash raybox.sh          # 首次运行进安装向导
raybox                  # 之后进菜单
```

向导会问：站点域名（同时作为 Reality SNI）、站点目录、入口端口（默认 443）、站点内部端口（默认 9443）、订阅域名、订阅端口。

依赖：`caddy`（站点与订阅）、`xray`（脚本会自动安装）。

## 菜单

```
1. 节点与站点信息     域名/端口/SNI/UUID/公钥/ShortID/回落
2. 订阅地址           mihomo、provider、sing-box、原生 vless
3. 内核与服务         重启 / 更新 / 日志
4. 自检               端口、回落、证书 CN、订阅
5. 修改配置           端口 / SNI / UUID / Reality 密钥
6. 卸载               停服务、删配置（站点目录保留）
```

`raybox check` 可在命令行直接跑自检。

## 订阅

```
https://<SUB_DOMAIN>:<SUB_PORT>/<token>/mihomo.yaml    完整 mihomo 配置
https://<SUB_DOMAIN>:<SUB_PORT>/<token>/provider.yaml  只有 proxies
https://<SUB_DOMAIN>:<SUB_PORT>/<token>/singbox.yaml   sing-box outbounds
https://<SUB_DOMAIN>:<SUB_PORT>/<token>/links.txt      vless:// 链接
```

`SUB_DOMAIN` 与 `DOMAIN` 分离是推荐做法：站点域（内容/伪装）与订阅域（接入）各自独立，一个域被封不连带另一个。两者不同时，订阅站点的证书由 Caddy 自动签发（HTTP-01，需要 80 端口可达）。

## 兼容性：Xray ≥26.9.8 的 REALITY 必须带 ML-KEM

Xray-core 从 **26.9.8** 起，REALITY 服务端要求客户端在握手时提供 `X25519MLKEM768` 密钥交换。**mihomo 默认不发**，表现是客户端报 `REALITY authentication failed`，服务端日志几乎无提示——非常容易误判成密钥或 ShortID 错。

因此本脚本生成的 mihomo 片段固定包含：

```yaml
reality-opts:
  public-key: ...
  short-id: ...
  support-x25519mlkem768: true
```

原生 `vless://` 链接同样带 `support-x25519mlkem768=true`。**升级 Xray 内核后如果 mihomo 突然连不上，先查这一项**，不要去动 UUID/ShortID。

## 自检与排障顺序

翻转拓扑的好处是**层级唯一**，按下面顺序查，不需要猜是模式还是内核的问题：

| 现象 | 结论 |
|---|---|
| 443 端口没监听 | xray 没起来 → `journalctl -u xray` |
| 443 能访问但看到的是别的东西 | `dest` 回落目标不对 |
| 443 返回站点内容 | 回落正常，链路没问题 |
| 443 正常、客户端连不上 | 凭据 / SNI / flow / mlkem |
| 9443 本地 200 而 443 不行 | 回落目标与站点端口不一致 |

## 测试

```bash
sudo bash tests/test-regression.sh            # 36 项：语法、函数、拓扑不变量、配置生成、订阅内容、健壮性
```

有 `xray` 的机器上会额外执行一次 `xray run -test` 验证生成的配置。

## 卸载

菜单 6 会停止并禁用 xray、删除 `/etc/raybox`、站点块与订阅块，**站点目录（/var/www/...）保留**。

## 历史

早期版本是 attach 模式（站点占 443、代理挂在 `/assets/<hex>` 路径后面，支持 WS/XHTTP）。该形态与翻转互斥，维护成本高、排障多一层，已整体移除；如需"借用他人站点"的场景，请从 git 历史取回旧版本，不要混在现网运维里。
