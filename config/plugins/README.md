# 远程插件源配置

这里放的是 App 的**在线数据源配置**。改完推到 `main`，用户下次启动 App 自动生效，**不需要发版**。

```
config/plugins/
├── index.json        索引：有哪些源、域名是什么、接口长什么样
├── maccms-json.js    通用 MacCMS JSON 解析脚本（多个源共用）
├── maccms-xml.js     通用 MacCMS XML 解析脚本（老站，输出结构与 JSON 版一致）
├── signed-demo.js    签名/加密类源模板（HMAC / AES / RSA 三种写法）
└── README.md         本文件
```

---

## 一、为什么要有这个目录

App 里有 19 个内置数据源，全部编译在包里。这带来一个无法绕开的问题：**源站换域名时，已经装出去的旧包改不了**。

2026-11-17 橘汁接口 `juziapp.hzhcbkj.cn` 整站 502（CDN 回源失败，源站自己挂了），官方其实已经发了新版、大概率换了域名。但用户手机上的旧包装的是旧域名，我们只能等下一次发版——而发版只对新装用户有效，老用户永远不会自己升级。

所以把「源是怎么配置的」从代码挪到这里。之后源失效，改一份 JSON 就行。

---

## 二、日常维护：源站换域名了

**只改一行**，脚本不用动：

```json
{
  "id": "js_bofeng",
  "baseUrl": "https://新域名.com",   ← 改这里
  "script": "config/plugins/maccms-json.js",
  ...
}
```

推到 `main`，用户下次启动自动生效。

> 生效时机：App 每次启动都会拉一次（URL 带小时级时间戳破 CDN 缓存）。所以改完大约需要用户重启一次 App，不是实时的。
>
> 如果希望老用户在下一次启动前也能用，改完最好同时在 App 里点一次「设置 → 刷新数据源配置」验证一下（该入口正在做）。

---

## 三、加一个新源

### 3.1 判断能不能用插件方式加

| 情况 | 能不能 |
| --- | --- |
| 标准 MacCMS JSON 采集接口（`provide/vod` + `code/list`） | ✅ 直接复用 `maccms-json.js`，只写配置 |
| 标准 MacCMS **XML** 采集接口（`<rss><list><video>`） | ✅ 复用 `maccms-xml.js`，只写配置 |
| 接口字段名不同（比如 `data.videos` 而不是 `list`） | ✅ 复制一份脚本改字段名 |
| 需要摘要/AES/RSA 计算的私有接口 | ✅ **可以了**，见 3.6 与 `signed-demo.js` |
| 详情页要跑 JS 渲染才能拿到数据 | ❌ 插件拿不到浏览器环境 |

> **2026-11 修订**：此前这里写的是「需要 AES/RSA 签名的私有接口 ❌ 保持内置」，
> 理由是 QuickJS 没有 crypto、没有二进制能力。**那个结论已经作废**——
> 宿主现在通过同步通道把加密原语注入给插件（见 3.6）。
> 如果看到旧文档或旧注释还这么说，以本节为准。

### 3.2 写配置

在 `index.json` 的 `plugins` 数组里加一项：

```json
{
  "id": "js_xinzhan",
  "name": "显示给用户看的名字",
  "baseUrl": "https://api.example.com",
  "script": "config/plugins/maccms-json.js",
  "description": "一句话说明（会显示在设置页）",
  "version": 1,
  "enabled": true,
  "categories": [
    { "id": "26", "name": "电影" },
    { "id": "31", "name": "国产剧" }
  ],
  "list":   { "path": "/api.php/provide/vod/", "query": { "ac": "list",   "t": "{category}", "pg": "{page}" } },
  "search": { "path": "/api.php/provide/vod/", "query": { "ac": "detail", "wd": "{keyword}", "pg": "{page}" } },
  "detail": { "path": "/api.php/provide/vod/", "query": { "ac": "detail", "ids": "{id}" } }
}
```

### 3.3 字段说明

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | ✅ | 源标识。**改了等于让老用户的收藏失效**（收藏记的是 `js_xxx`）。只允许小写字母/数字/下划线/连字符 |
| `name` | ✅ | 设置页里显示的名字 |
| `baseUrl` | ✅ | 站点根地址。**换域名时只改这里** |
| `script` | ✅ | 解析脚本路径，必须以 `config/plugins/` 开头 |
| `categories` | | 分类列表。空数组表示不支持浏览，但至少要有 `search`，否则用户切过去是空白页，配置会被拒绝 |
| `list` | | 分类列表请求。`null` = 不支持浏览 |
| `search` | | 搜索请求。`null` = 不支持搜索 |
| `detail` | | 详情请求。`null` = 详情页只有列表里的信息 |
| `resolve` | | 取播放地址请求。**不配** = `detail` 给的地址可直接播（多数 MacCMS 站如此） |
| `signEntry` | | 签名钩子的函数名。配了就在每次请求前调它，见 3.6。不配 = 不需要签名 |
| `vars` | | 自定义变量，配置里用 `{vars.xxx}` 引用，解析脚本里用 `ctx.vars.xxx`，**签名脚本里用 `req.vars.xxx`** |
| `defaultHeaders` | | 所有请求默认带的头（UA / Referer） |
| `enabled` | | `false` = 下架这个源（比删掉好，用户本地缓存会一起清掉） |
| `version` | | 仅用于排障，不参与逻辑 |

### 3.4 请求里的占位符

| 占位符 | 含义 |
| --- | --- |
| `{page}` | 页码 |
| `{keyword}` | 搜索词（自动 URL 编码） |
| `{id}` | 条目 id |
| `{category}` | 分类 id |
| `{vars.x}` | `vars` 里的变量 |

**不要自己拼 URL**。清单负责「请求什么」，脚本只负责「怎么解析」——这条分界让 90% 的失效（换域名、改接口路径）都不用碰脚本。

### 3.5 请求头限制

`defaultHeaders` 和每条请求的 `headers` 里**不允许**出现 `Host` / `Cookie` / `Authorization`，写了会被拒绝：

- `Host` 会打乱 TLS 的 SNI 与证书校验，等于把请求伪装到别的站；
- `Cookie` / `Authorization` 是凭证，不该出现在公开仓库里。

### 3.6 签名类源（配 `signEntry`）

QuickJS 自己**没有** crypto，所以宿主把加密原语注入进去。这些函数在脚本里是**同步**的（实测单次往返 0.15ms），所以插件入口依然是普通同步函数：

```js
host.md5(s) / host.sha1(s) / host.sha256(s)
host.hmac(algo, key, msg)          // algo: md5/sha1/sha256/sha512
host.aesEcbEncrypt({key, plain, keyFmt?, plainFmt?, outFmt?})
host.aesEcbDecrypt({key, cipherText, ...})
host.aesCbcEncrypt({key, iv, plain, ...})
host.aesCbcDecrypt({key, iv, cipherText, ...})
host.rsaEncrypt({nHex, e?, data, ...})   // PKCS#1 v1.5 公钥加密
host.b64e(s) / host.b64d(s) / host.hex(s) / host.unhex(s)
host.xml2json(xml)
host.randomHex(n) / host.randomAlnum(n)
host.available(name) / host.names()      // 自检，便于写降级
```

`*Fmt` 参数取值 `'utf8'`（默认）/ `'hex'` / `'base64'`，**必须显式说明**——猜错的表现是「加密结果和服务端对不上」，极难排查。

失败时 `host.xxx` 会**抛 JS 异常**（不是返回错误对象），所以用 `try/catch`：

```js
try { var h = host.md5('x'); } catch (e) { /* e.message 是人话 */ }
```

#### 签名钩子的形态

配了 `signEntry: "sign"` 之后，宿主在**每次发请求前**调用它：

```js
// 入参：{url, method, query, headers, body, vars, ctx:{baseUrl, sourceId}}
// 返回：{headers?, query?, body?} —— 只返回要改的，没返回的宿主不动
function sign(req) {
  var ts = String(new Date().getTime());
  var nonce = host.randomAlnum(16);
  var sig = host.hmac('sha256', req.vars.secret, pathOf(req.url) + ts + nonce);
  return { headers: { 'x-ts': ts, 'x-nonce': nonce, 'x-sign': sig } };
}
```

三条要点：

1. **`vars` 在 `req` 顶层**，不是 `req.ctx.vars`。写错会取到空值，表现是「一个签名头都没发」。
2. **待签串里不要放主机名**。服务端只看到 path；而且采集站换域名是常态，主机名进了签名会导致换域名当天全部失效。
3. **不能设置 `Host` / `Cookie` / `Authorization`**。命中会让整个请求作废（不是过滤后继续发——那会让作者以为签名生效了）。

完整可运行示例见 `signed-demo.js`，里面还有 AES 加密请求体、RSA 签名两种写法。

---

## 四、写脚本

脚本在 QuickJS 里跑，标准 JS 语法都可用（JSON / RegExp / String / Array / Date / encodeURIComponent）。但有四条硬约束：

### 4.1 必须同步

入口函数返回 Promise 会被**直接拒绝**。所有网络请求由宿主发起，脚本只做「字符串 → 对象」。

```js
// ✅ 对
function parseList(body, ctx) { return { items: [...] }; }

// ❌ 错：返回 Promise
async function parseList(body, ctx) { ... }
```

**为什么不支持 async**：宿主已经承担了全部 IO，解析不需要 await。允许 async 只会让作者以为 await 生效了（实际拿到 Promise），或者让插件自己发请求——那就绕过了宿主的 SSRF 防护。

### 4.2 不能写死循环

宿主在装载前会静态检查 `while(true)` / `while(1)` / `for(;;)`，发现就拒绝执行。

**这不是安全边界，是防手滑**——而且背后有个很硬的现实：**JS 引擎的死循环宿主杀不掉**。实测 `QuickJsRuntime2(timeout: 1)` 跑 `while(true){}`，89 秒后仍未返回；`Isolate.kill()` 对它也无效（15 秒收不到退出信号，线程继续空转）。所以只能从源头拦。

### 4.3 三个入口函数

```js
function parseList(body, ctx)    → { items: [{ id, name, pic, remark, brief, area, year }] }
function parseDetail(body, ctx)  → { name, content, pic, year, area, remark,
                                      lines: [{ line, episodes: [{ name, url }] }] }
function parseResolve(body, ctx) → { url: "http://..." }   // 配了 resolve 才需要
```

`ctx` 是对象：`{ vars, baseUrl, finalUrl, sourceId }`

**XML 站**用 `maccms-xml.js`，入口函数名完全相同，输出结构也完全相同——所以 `index.json` 里换个 `script` 字段就能在两种格式间切换，下游（界面、收藏、播放）都不用动。

写 XML 脚本时两个坑已经在那份脚本里兜掉了，自己写新脚本时要注意：

- **单个子元素不是数组**：`<list><video>…</video></list>` 里 `video` 是对象，两个以上才是数组；
- **带属性的元素文本在 `#text` 里**：`<dd flag="x">第1集$url</dd>` 取 `dd` 得到的是 `{"@flag":"x","#text":"第1集$url"}`。

### 4.4 返回对象即可，不用 stringify

宿主会自动 `JSON.stringify`。返回字符串也支持（原样使用）。

### 4.5 可用能力一览

- **标准 JS 全集**：JSON / RegExp / String / Array / Math / Date / encodeURIComponent
- **宿主注入的 `host.*`**：见 3.6（摘要、AES、RSA、编码、XML 解析、随机）
- **没有的**：`require` / `process` / `fetch` / `XMLHttpRequest` / `setTimeout` / `console`

`console.log` 会有输出但**不进 App 日志**，调试请在本地用 Node 跑通再上传（脚本只用标准 JS + `host.*`，把 `host` 用 Node 里的等价实现桩一下即可）。

---

## 五、App 侧的行为

### 5.1 加载顺序

```
启动 → 读本地缓存（立即生效）→ 后台拉远端 → 成功则替换
```

三层兜底：**远端 → 本地缓存 → 空**。任何一层失败都静默降级，不弹提示。

### 5.2 国内镜像

配置和脚本都托管在 GitHub。实测（2026-11-17 本机直连）：

| 地址 | 结果 |
| --- | --- |
| `raw.githubusercontent.com` | **HTTP 000**（连不上） |
| `cdn.jsdelivr.net` | **HTTP 000**（连不上） |
| `raw.gitmirror.com` | **HTTP 000**（连不上） |
| `ghproxy.net` | 200，1.37s ✅ |
| `gh-proxy.com` | 200，1.05s ✅ |

所以镜像不是优化项，是前提。App 按顺序试，第一个成功的记住，**脚本也从同一个镜像取**——如果索引从 ghproxy 拿到、脚本却去 raw 拿，那脚本必然失败，表现为「配置里有源但一个个都坏」。

### 5.3 单条坏配置不影响其他

`index.json` 里某一条写错，只会跳过那一条（日志里能看到原因），其他源照常工作。

但如果**全部**都失败，App 会保留旧缓存——旧源至少还能用，新配置是坏的。

### 5.4 路径限制

`script` 必须位于 `config/plugins/` 下，不允许包含 `..`。允许任意路径等于让远程配置能下载仓库里任何文件，没有正当用途只有风险。

---

## 六、验证

改完配置后，本地可以这样确认文件能被解析：

```bash
cd code/flutter_app
flutter test test/plugin_manifest_test.dart
```

真机验证：装 App → 设置 → 数据源 → 找「插件（在线更新）」分组。

日志里能看到加载结果：

```
[PLUGIN] loaded 2 from https://ghproxy.net/...
[PLUGIN] js_xxx: 分类为空
```

---

## 七、已下线的源

| 源 | 下线原因 |
| --- | --- |
| —— | —— |

下线的源把 `enabled` 设为 `false`，不要直接删——删了之后老用户的本地缓存会一起消失，没法回溯「它当时配的是什么」。