# 远程插件源配置

这里放的是 App 的**在线数据源配置**。改完推到 `main`，用户下次启动 App 自动生效，**不需要发版**。

```
config/plugins/
├── index.json        索引：有哪些源、域名是什么、接口长什么样
├── maccms-json.js    通用 MacCMS JSON 解析脚本（多个源共用）
├── maccms-xml.js     通用 MacCMS XML 解析脚本（老站，输出结构与 JSON 版一致）
├── maccms-html.js    通用 MacCMS 网页模板脚本（片库 pianku）
├── yuny.js           云影：纯 App JSON 接口（POST JSON body，非 MacCMS）
├── jisu.js           极速追剧：HTML + 独立取址接口，逐线路集数不同
├── kvm4k.js          4K影视：Go SSR + WASM 取址算法还原，signEntry 签名
├── kanju.js          看剧：HMAC 四行签名 + 分区榜单 + 线路 JSON
├── ddys.js           低调影视（ddys.io）：详情页直出 m3u8
├── signed-demo.js    签名/加密类源模板（HMAC / AES / RSA 三种写法）
└── README.md         本文件
```

---

## 一、为什么要有这个目录

**App 包里一个内置源都没有。** 所有源——包括原来的那批采集站——都通过这份配置下发。这是刻意的：只要还有一个源编译在包里，它换域名时就只能等发版。

这个限制不是假设出来的。2026-11-17 橘汁接口 `juziapp.hzhcbkj.cn` 整站 502（CDN 回源失败，源站自己挂了），官方其实已经发了新版、大概率换了域名。但用户手机上的旧包装的是旧域名，我们只能等下一次发版——而发版只对新装用户有效，老用户永远不会自己升级。

所以把「源是怎么配置的」整体挪出来。之后任何源失效，改一份 JSON 就行，与装的是哪个版本的包无关。

> 直接后果：注册表初始是**空的**，这是合法状态而不是异常。空的时候界面走占位源，不崩也不空白。设计细节见 `SourceRegistry` 与 `OfflineSource`。
>
> 另一个后果：换源、改分类只需推仓库，**不需要发版**。新增一个源同理——写个 JS、加一条 JSON，用户重启就有了。

---

## 二、日常维护：源站换域名了

**只改一行**，脚本不用动：

```json
{
  "id": "bofeng",
  "baseUrl": "https://新域名.com",   ← 改这里
  "script": "config/plugins/maccms-json.js",
  ...
}
```

推到 `main`，用户下次启动自动生效。

> **id 不带 `js_` 前缀**。源全在远端之后，「插件源」和「内置源」不再有区别，加前缀只会让同一个站在列表里出现两次。id 是收藏/历史持久化的键，一旦定下就要保持稳定。

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
| protobuf 请求/响应（橘汁） | ✅ `bodyFormat:"hex"` + `responseType:"bin"`，见 3.3.4 |
| 详情页要跑 JS 渲染才能拿到数据 | ❌ 插件拿不到浏览器环境 |
| 需要跨请求 Cookie 会话 / 图形点选验证码 | ❌ 见本文件末尾「已知边界」 |

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
| `id` | ✅ | 源标识。**改了等于让老用户的收藏失效**。只允许小写字母/数字/下划线/连字符 |
| `name` | ✅ | 设置页里显示的名字 |
| `baseUrl` | ✅ | 站点根地址。**换域名时只改这里** |
| `script` | ✅ | 解析脚本路径，必须以 `config/plugins/` 开头 |
| `categories` | | 分类列表。空数组表示不支持浏览，但至少要有 `search`，否则用户切过去是空白页，配置会被拒绝 |
| `home` | | 推荐位请求。**不配 = 复用 `list` 并传空分类**。只在「推荐」和「分类」是两个不同端点时才需要，见 3.3.1 |
| `list` | | 分类列表请求。`null` = 不支持浏览 |
| `search` | | 搜索请求。`null` = 不支持搜索 |
| `detail` | | 详情请求。`null` = 详情页只有列表里的信息 |
| `resolve` | | 取播放地址请求。**不配** = `detail` 给的地址可直接播（多数 MacCMS 站如此） |
| `group` | | 切换面板里的分组名，如 `采集站（直连）` / `需系统代理`。**留空按「采集站（直连）」处理** |
| `lineNameCn` | | 线路代号 → 中文名映射，如 `{"bfzym3u8": "暴风线路"}`。未命中的代号原样显示 |
| `preferDirectLine` | | 是否把直出 m3u8/mp4 的线路排到最前。**默认 `true`**，见 3.3.2 |
| `derivePlayIndex` | | 是否把 `/play/<token>` 推成 `/play/<token>/index.m3u8`。默认 `false` |
| `batchDetail` | | 列表拿到 id 后是否再用 `detail` 的 `ids=` 批量回查补封面。默认 `false`，见 3.3.5 |
| `expandLines` | | 详情只给占位线路时，是否先 resolve 第一集拿线路模板再展开。默认 `false`，脚本需实现 `parseLines`，见 3.3.6 |
| `dropIndirectLines` | | 无 `resolve` 时是否隐藏网页分享页线路（只留可播的直出线）。默认 `false` |
| `searchUnsupported` | | 站方根本没开放搜索时标 `true`。搜索页直接给解释、不发请求，见 3.3.7 |
| `signEntry` | | 签名钩子的函数名。配了就在每次请求前调它，见 3.6。不配 = 不需要签名 |
| `bodyFormat` | | 请求体承载格式：`text`（默认）/ `hex` / `base64`。**二进制请求体必须显式声明**，见 3.3.4 |
| `responseType` | | 响应形态：`text`（默认）/ `bin`。`bin` 时宿主把原始字节转 base64 交给脚本 |
| `vars` | | 自定义变量，配置里用 `{vars.xxx}` 引用，解析脚本里用 `ctx.vars.xxx`，**签名脚本里用 `req.vars.xxx`** |
| `defaultHeaders` | | 所有请求默认带的头（UA / Referer） |
| `enabled` | | `false` = 下架这个源（比删掉好，用户本地缓存会一起清掉） |
| `version` | | 仅用于排障，不参与逻辑 |

#### 3.3.1 `home`：推荐位是独立接口时

有一类站（云影）把推荐和分类做成了**两个端点，连分页字段名都不同**：

```jsonc
"home": {                      // POST /app/video-home/today-updates
  "path": "/app/video-home/today-updates",
  "method": "POST",
  "body": "{\"pageNo\":{page},\"pageSize\":18,\"type\":\"剧集\"}",
  "bodyType": "json"
},
"list": {                      // POST /app/video-search/label-v2
  "path": "/app/video-search/label-v2",
  "method": "POST",
  "body": "{\"current\":{page},\"size\":18,\"type\":\"{category}\"}",
  "bodyType": "json"
}
```

一个模板不可能同时对上 `pageNo` 和 `current`。没有 `home` 时，「推荐」会退回走 `list` 并传空分类——这对采集站是对的（`t` 为空 = 全站最新），对这类站就只能拿到「最新入库」，失去站方编排的推荐位。

> **注意**：只有 `home` 没有 `list` 的源**是合法的**，`canBrowse` 会认它。早期只看 `list`，这类源会被判成「既不能浏览也不能搜索」直接丢弃。

#### 3.3.2 `preferDirectLine`：为什么默认开

2026-11-13 实测：这批采集站给同一部剧常下发两条线路，第一条是 `…/share/<md5>` 的**网页页**，第二条才是直出 m3u8。播放器默认取第一条，而网页分享页靠 JS 渲染，抓下来连 m3u8 都抠不出来——用户看到的是「点进去一直转圈」。

默认开 = 新接入的站不用摸清线路顺序也是好的。确实要保留站点原始顺序的，显式写 `"preferDirectLine": false`。

排序实现是**手写两段拼接**而不是 `sort`：Dart 的 `List.sort` 不保证稳定，同组内相对次序一旦被打乱，用户熟悉的「线路1/线路2」就变了。

2026-11-17 补充：`preferDirectLine` 只是排序，网页线仍在面板里，用户逐条试就会踩坑。对**没有 `resolve` 接口**的源，再开 `dropIndirectLines: true` 直接隐藏网页线——留着它们对播放器毫无价值。有 `resolve` 的源别开，网页线还能二次解析出地址。

#### 3.3.3 `bodyType`：JSON body 必须显式声明

采集接口的 POST 有两种截然不同的形态，混用一定失败：

| `bodyType` | Content-Type | 典型来源 |
| --- | --- | --- |
| `form`（默认） | `application/x-www-form-urlencoded` | MacCMS 系 `wd=关键词&pg=2` |
| `json` | `application/json` | 云影这类自研 App 接口 |

用表单发 JSON 的 body，服务端会收到一个键叫 `{"current":1,...}` 的畸形字段，返回 400 或「参数缺失」——而现象是**这个源永远搜不到东西**，完全看不出是编码问题。

配了 `json` 之后，占位符替换会**按 JSON 字符串规则转义**（`\` `"` 换行 制表符）。这不是过度设计：搜索 `"引号"` 这种词时裸替换会拼出 `{"key":""引号""}`，非法 JSON，而服务端报的仍然是「参数缺失」。

#### 3.3.4 `bodyFormat` / `responseType`：二进制通道

橘汁是 protobuf 接口，请求和响应都是二进制。两个方向各有一个坑：

- **请求**：Dio 拿到 `String` 会按 UTF-8 编码，把 `>=0x80` 的字节展开成两三个字节，服务端收到的是被污染的帧；
- **响应**：`ResponseType.plain` 按 UTF-8 解码，varint 与长度前缀会被替换成 U+FFFD；而且 `JsEvalResult.stringResult` 跨 FFI 是 C 字符串，中间的 `\u0000` 会截断内容。

所以：

```jsonc
"search": {
  "path": "/api/proto/v5/drama/search",
  "method": "POST",
  "body": "",              // 真正的体由 sign 钩子现算
  "bodyFormat": "hex",     // 宿主把 hex 解码成原始字节发出
  "responseType": "bin"    // 宿主把原始字节 base64 后交给脚本
}
```

脚本侧用 `host.b64d(body, 'hex')` 拿回字节的 hex 表示，自己写 protobuf 阅读器（原 `zhuiju.js` 有完整实现，源已下线，脚本见 git 历史）。**别用 `JSON.parse` 去接二进制响应**。

`bodyFormat` 在签名钩子改写 body 后**会重新解码一次**——橘汁的随机密文体就是这么进去的。

#### 3.3.5 `batchDetail`：列表快 + 封面全，怎么兼得

2026-11-17 实测电影天堂：

| 方案 | 体积 | 耗时 | 封面 |
| --- | --- | --- | --- |
| `ac=detail&pg=1`（旧） | 885 KB | 12.6 秒 | 有 |
| `ac=list&pg=1` | 6 KB | 0.7 秒 | **无** |
| `ac=list` + 批量 `ac=detail&ids=a,b,c…` | 62 KB | 2.0 秒 | 20/20 补齐 |

所以采集站列表统一用 `ac=list` + `batchDetail: true`。批量回查走宿主现成的 `_enrichByBatchDetail`（按原顺序回填，失败时保留无封面列表而不是让整页变空）。金鹰的批量接口实测超时，因此它保留 `ac=detail`。

#### 3.3.6 `expandLines`：线路清单藏在 resolve 接口里的站

看剧（kanju）的详情只给剧集 token，线路清单在 `/v1/playback/resolve/{token}` 的 `line_options[]`（实测 33 条、23 条直出）。不展开的话用户只能选一条「默认线路」。

配 `expandLines: true` 后，宿主在详情阶段 resolve 第一集拿模板，调脚本的 `parseLines(body, ctx)` → `{lines:[{line:"线路名"}]}`，展开成多条线路。要点：

- **只 resolve 第一集**：线路清单跨集稳定；逐集 resolve 会把详情页拖成几十次请求。
- `parseLines` 应只返回**当前体系能播的**线路。看剧的官方线要游客会话二次换票（插件禁止注入 Cookie），所以脚本过滤掉 `resolve_required: true`，只给直出线。
- **顺序照抄站点**：`parseLines` 返回的顺序就是面板顺序，宿主不再按"直出/网页"分区重排（`expandLines: true` 时 `preferDirectLine` 自动失效）。2026-11-17 用户明确要求「线路按人家原版线路顺序，不要自己排序」。
- 展开后每条线路的 `sourceCn` 是线路名，`parseResolve` 用 `ctx.line` 精确选中对应那条；站点某集缺这条线时回退第一条直出，不让用户看到空白。

#### 3.3.7 `searchUnsupported`：站方把搜索接口焊死的站

索尼资源（suoni）实测：`?ac=list&wd=关键词` 恒返回 **18 字节纯文本「暂不支持搜索」**。换 UA、补 `Referer`/`Origin`、加 `X-Requested-With`、加 `Accept` 全试过，一字不差。而 `keyword=关键词` 虽然不回 403，返回的却是与关键词无关的默认列表——那不是搜索，不能拿来充数。

这类源标 `searchUnsupported: true`：

- 搜索页**一个请求都不发**，直接给「这个源搜不了 / 站方没有开放搜索，换个源搜，或从它的分类里找」。
- 不走带「重试」按钮的错误页——这不是失败，重试一百次也是同一句话。
- 该源的 `search` 端点配置留着即可（配置可读性），宿主会忽略它。

**别拿它掩盖真实故障**：只有在「源站明确拒搜」时才开。请求超时、解析失败、接口改地址都该照常报错，标了反而是把故障说成限制。

### 3.4 请求里的占位符

| 占位符 | 含义 |
| --- | --- |
| `{page}` | 页码 |
| `{keyword}` | 搜索词（自动 URL 编码） |
| `{id}` | 条目 id |
| `{category}` | 分类 id |
| `{vars.x}` | `vars` 里的变量 |
| `{token}` | 单集标识（kvm4k 的 dataid、kanju 的 episode token、橘汁的 video id） |
| `{token0}` / `{token1}` | 复合 token 按 `|` 拆出的段。极速追剧用它传 `prefix|ep` 给取址接口 |

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
host.b64e(s, fmt) / host.b64d(s, outFmt) // 注意是位置参数，fmt 如 'hex'/'utf8'
host.hex(s, fmt) / host.unhex(s, outFmt)
host.xml2json(xml)
host.randomHex(n) / host.randomAlnum(n)
host.available(name) / host.names()      // 自检，便于写降级
```

`*Fmt` 参数取值 `'utf8'`（默认）/ `'hex'` / `'base64'`，**必须显式说明**——猜错的表现是「加密结果和服务端对不上」，极难排查。

失败时 `host.xxx` 会**抛 JS 异常**（不是返回错误对象），所以用 `try/catch`：

```js
try { var h = host.md5('x'); } catch (e) { /* e.message 是人话 */ }
```

> **签名函数与编码函数是位置参数，加密函数是对象参数**：
>
> ```js
> host.hmac('sha256', key, msg)   // ✅ 三个位置参数
> host.b64e(hex, 'hex')           // ✅ 两个位置参数
> host.hmac({ algo:'sha256', key:key, msg:msg })  // ❌ 算的是 "[object Object]"
> host.b64e({ s:hex, fmt:'hex' })                 // ❌ 同上，且不报错
> ```
>
> 这个坑是实测踩出来的：把对象传给 `hmac`，脚本照常返回 32 位 hex，看起来完全正常，只有和 Dart 实现**逐字段对拍**才会发现签名对不上。凡是签名类源，测试里都要有一条固定输入的对拍断言。

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
# 18 个源的配置整体校验（id 重复 / 脚本路径 / signEntry / 死循环）
flutter test test/plugin_index_validation_test.dart
# 单个源的解析脚本（QuickJS 真实引擎 + 真实抓包夹具）
flutter test test/maccms_html_plugin_test.dart test/jisu_plugin_script_test.dart \
            test/kvm4k_plugin_script_test.dart test/kanju_plugin_script_test.dart \
            test/ddys_plugin_script_test.dart
```

真机验证：装 App → 设置 → 数据源 → 找「插件（在线更新）」分组。

日志里能看到加载结果：

```
[PLUGIN] loaded 2 from https://ghproxy.net/...
[PLUGIN] js_xxx: 分类为空
```

---

## 七、已知边界（当前插件体系做不到）

| 场景 | 现状 |
| --- | --- |
| 跨请求 Cookie 会话（看剧的游客会话） | 宿主禁止脚本设置 `Cookie`/`Authorization`，也没有 Cookie jar。看剧插件只展开直出线路（实测每集 23 条），**官方线暂不可用** |
| 索尼资源搜索 | 站方对 `wd=` 参数直接回「暂不支持搜索」；改用 `keyword=` 虽绕过拦截但返回的是全量列表（测试三种关键词结果完全相同），等于没搜索。这是源站限制，插件层无解 |
| 图形点选验证码（ddys.app 的第三层闸门） | 需要看图识别，客户端无感通过做不到。改用同系列无闸门的 `ddys.io`，内置源也是这么做的 |
| 需要浏览器 DOM/JS 渲染的页面 | 插件只有字符串，没有 DOM。采集站的 `share/<md5>` 网页线属于这类，`dropIndirectLines: true` 会隐藏它们 |

## 八、已下线的源

| 源 | 下线原因 |
| --- | --- |
| 橘汁（`zhuiju`） | 2026-11-17 起主域名 `juziapp.hzhcbkj.cn` 整站 502，用户实测全部接口超时。按用户要求彻底移除：清单条目、`zhuiju.js` 脚本、专属联网探针一并删除。内置 `ZhuijuSource` 类保留供兼容旧收藏，但不再注册进源列表 |

橘汁是**彻底删除**而非设 `enabled: false`：它依赖专属的 protobuf + AES/RSA 脚本，脚本删了之后留一个禁用的清单条目没有意义。其它源下线时仍优先用 `enabled: false`（保留可回溯的配置）。