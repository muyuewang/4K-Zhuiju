# 接口地址下发配置

这个目录里的文件会被 App 在启动时从远端拉取，用来覆盖编译进包里的默认接口地址。改这里并推送到 `main` 分支，**已安装的 App 下次启动就会用上新值，不需要重新发版**。

## 为什么需要这个

橘汁的接口域名是运营方动态下发的，历史上换过多次。如果写死在客户端里，对方一换服务器，所有装旧包的用户同时打不开，只能等下一次发版——而发版要审核、要用户手动更新，中间这几天就是全黑。

2026-11-17 就发生过一次：`juziapp.hzhcbkj.cn` 整站 502（CDN 回源失败，源站自己挂了），而官方官网仍在正常更新、已经发了 v3.0.7.1。对方只是换服务器，我们这边却完全失联。

## 文件格式

`endpoints.json`：

```json
{
  "zhuijuBase": "http://juziapp.hzhcbkj.cn"
}
```

| 字段 | 说明 |
|---|---|
| `zhuijuBase` | 橘汁接口根地址，只写「协议 + 域名 + 可选端口」 |

`_comment` 字段会被忽略，随便写。

## 只会接受合法值

`zhuijuBase` 必须满足（见 `lib/core/remote_endpoints.dart` 的 `isValidBase`，有 17 条单测钉着）：

- scheme 只能是 `http` 或 `https`
- 必须有 host
- **不能带用户名密码**（无正当用途，且是配置被劫持时最直接的凭证泄漏形态）
- **不能带路径**（接口路径由代码拼接，base 带路径会拼出 `/api/api/proto/...`）
- 长度不超过 200

**写坏了不会生效，也不会把 App 改死**：非法值会被丢弃，退回本地缓存或内置默认值。所以改错了不会造成事故，只是没效果——看日志里 `[CFG] invalid zhuijuBase` 就知道。

## 生效时机与兜底顺序

启动时按这个顺序：

1. 读本地缓存（上一次成功拉到的值）→ 立即生效，**在任何网络请求之前**
2. 后台异步拉远端配置 → 拉到了就热更新，拉不到就算了
3. 都失败 → 用编译进包的 `ZhuijuApi.defaultHost`

远端拉取会按顺序试两个镜像：

```
https://ghproxy.net/https://raw.githubusercontent.com/muyuewang/4K-Zhuiju/main/config/endpoints.json
https://raw.githubusercontent.com/muyuewang/4K-Zhuiju/main/config/endpoints.json
```

第一个是国内可达的镜像（实测直连 ~1s），第二个是原始地址（留给本来就能直连的环境）。都不通就用缓存，不会因为配置拉不到而弹任何错误——「配置没拉到」不是用户需要知道的事。

请求带小时级时间戳打破 CDN 缓存，所以改完大约一小时内生效。

## 换域名时的操作

1. 改 `endpoints.json` 里的 `zhuijuBase`
2. 推到 `main`
3. 等一到两小时（CDN 缓存），或用户下次冷启动时生效

**注意**：如果对方连协议都改了（不只是域名），这个机制救不了——那就必须发版。这里只解决「地址变了」这一类问题，不试图接管接口协议：协议、字段映射这些改错会让整个源解析失败且无法回滚，不适合远程下发。

## 验证远端文件能否取到

```bash
curl -s "https://ghproxy.net/https://raw.githubusercontent.com/muyuewang/4K-Zhuiju/main/config/endpoints.json"
```

返回 JSON 就说明链路通了。