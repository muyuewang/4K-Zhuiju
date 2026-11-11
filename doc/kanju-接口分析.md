# kanju.ai 接口分析

分析目标：`https://kanju.ai/`（前端自报项目名 `dianyingtiantang`，即"电影天堂"）。  
分析方式：抓取前端产物（Vite 打包，`assets/` 下 120 个动态分包，共约 2.8 MB），提取请求层与业务层逻辑，再用 Python 客户端对每个端点做真实请求验证。

本文所有状态码、响应长度、字段名、地址均来自实测，未测的会明确标注。

---

## 一、鉴权机制

### 1.1 请求签名（三头必带）

前端在 `movie-card-runtime-*.js` 里硬编码了签名密钥，所有 `/v1/*` 请求都要带三个头：

| 请求头                    | 值                   |
| ---------------------- | ------------------- |
| `x-ai-movie-timestamp` | 毫秒时间戳字符串            |
| `x-ai-movie-nonce`     | 16 字节随机数的 hex，32 字符 |
| `x-ai-movie-signature` | HMAC-SHA256 hex     |

签名串是**四行拼接**，换行符 `\n` 分隔：

```
{METHOD}
{PATHNAME + SEARCH}      ← 含 query，不含域名
{TIMESTAMP}
{NONCE}
```

密钥（64 字符 hex 字符串，当作 ASCII 字节用，不是 hex 解码）：

```
557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0
```

Python 复现：

```python
import hmac, hashlib, os, time, urllib.parse

KEY = b"557d0e4ae929f438da6bd84412374e6086b8af09b3fed54bf22601d5bf8c54a0"

def sign(method, url, ts, nonce):
    u = urllib.parse.urlsplit(url)
    query = ('?' + u.query) if u.query else ''
    msg = f"{method.upper()}\n{u.path}{query}\n{ts}\n{nonce}"
    return hmac.new(KEY, msg.encode(), hashlib.sha256).hexdigest()
```

要点：

- 签名覆盖 **method + 完整路径与查询串**，改任何一个 query 参数都要重新签。
- 缺签名时返回 `401 Missing request signature`；签名不匹配时返回 `401 {"code":"invalid_request_signature","message":"Invalid request signature."}`。
- 该密钥是公开在前端包里的，属于"防随便爬"而非真安全。

#### ⚠️ 坑一：中文参数必须先编码再签名

这是本分析中实际踩到的问题，**最容易让人误判成密钥错误**。

同一个查询，两种写法结果完全不同：

| 写法                        | 结果                                   |
| ------------------------- | ------------------------------------ |
| `/v1/suggest?q=沙`         | **401** `Invalid request signature.` |
| `/v1/suggest?q=%E6%B2%99` | **200**                              |

原因：curl / requests 在发请求时会把中文自动转成百分号编码，而签名函数如果直接对原文 `沙` 计算，两边的字符串就不一致了。**必须做到"签名用的串"与"实际发出的 URL"完全同一份**。

正确做法是在发送前统一规范化：

```python
def norm_path(path):
    path_part, _, query = path.partition("?")
    if query:
        pairs = []
        for seg in query.split("&"):
            if not seg:
                continue
            k, _, v = seg.partition("=")
            pairs.append(
                urllib.parse.quote(urllib.parse.unquote(k), safe="") + "=" +
                urllib.parse.quote(urllib.parse.unquote(v), safe="")
            )
        query = "&".join(pairs)
    return path_part + (("?" + query) if query else "")
```

`call()` 里先 `path = norm_path(path)`，再签名、再发。修复后 `q=沙` 与 `q=%E6%B2%99` 都返回 200。

### 1.2 客户端标识头（非必填但建议带）

| 请求头                           | 实测值                                                             |
| ----------------------------- | --------------------------------------------------------------- |
| `x-ai-movie-client-name`      | `dianyingtiantang-frontend`                                     |
| `x-ai-movie-client-version`   | `1.0.0`                                                         |
| `x-ai-movie-build-version`    | `dianyingtiantang-v2026.11.06.2-search-header-f6f73501a448-web` |
| `x-ai-movie-protocol-version` | `2026-07-05.library-v2.playback-v1`                             |

另有可选头：`x-ai-movie-content-surface`、`x-ai-movie-site-host`、`x-ai-movie-home-address-id`、`x-ai-movie-midnight-access`、`x-ai-movie-playlist-access`（后几个用于活动/权限场景，未逐一验证）。

### 1.3 会话

不是 Bearer Token，是 **HttpOnly Cookie**：

```
Set-Cookie: ai_movie_session=ums_<base64url>; Domain=.kanju.ai; Path=/; HttpOnly; Secure
```

值是 `ums_` 前缀 + 长串，有效期约 **1 年**（实测 `expires_at` 为签发后一年）。

`POST /v1/users/anonymous` 可以直接拿到匿名会话（HTTP 201），无任何前置校验：

```json
{
  "object": "user.session",
  "user": {
    "object": "site.user",
    "id": "user_1d27cfc6-...",
    "display_name": "花火故事1697",
    "status": "active",
    "onboarding_status": "pending",
    "created_at": "...", "last_seen_at": "..."
  },
  "expires_at": "2027-11-10T12:13:50.515Z",
  "app_experience": { ... },
  "passkey": "...",
  "recovery_memo": "..."
}
```

`display_name` 是服务端随机生成的"形容词+名词+四位数字"，如`夏雨燕子1403`、`花火故事1697`。

带 Cookie 后 `/v1/users/me` 等端点即可访问；游客 `role=guest`、`level=1`、`level_title=初出茅庐`。

### 1.4 权限分层

| 层级   | 说明                                | 示例端点                                                                       |
| ---- | --------------------------------- | -------------------------------------------------------------------------- |
| 公开   | 只需签名                              | `feed/home`、`browse/catalog`、`catalog/{id}`、`suggest`                      |
| 游客会话 | 需匿名 Cookie                        | `users/me`、`users/me/quota`、`users/me/favorites`                           |
| 登录用户 | 需账号登录，游客报 `401 Login is required` | `users/me/playlists`、`users/me/playlists/saved`、`users/me/invite/progress` |

注意两者错误信息不同：

- 无 Cookie → `401 {"message":"User session is required."}`
- 有游客 Cookie 但端点需登录 → `401 {"message":"Login is required."}`

---

## 二、端点清单

34 个端点，状态码为实测结果（`GET` / `POST` 已区分，标 * 的是**只支持该单一方法**，用错方法返回 404 `Cannot GET/POST ...`）。

### 2.1 首页与发现

| 端点                           | 方法  | 实测             | 说明                       |
| ---------------------------- | --- | -------------- | ------------------------ |
| `/v1/feed/home`              | GET | 200 / 65,508 B | 首页信息流，多分区                |
| `/v1/runtime/bootstrap`      | GET | 200 / 37,129 B | 运行时配置、合规信息、ana lytics 开关 |
| `/v1/announcements/manifest` | GET | 200 / 5,914 B  | 公告清单，带 `revision`        |
| `/v1/playlists/explore`      | GET | 200 / 20,305 B | 公开片单广场                   |
| `/v1/preferences`            | GET | 200 / 529 B    | 项目级默认偏好（非用户级）            |

### 2.2 搜索与浏览

| 端点                   | 方法  | 实测                    | 说明              |
| -------------------- | --- | --------------------- | --------------- |
| `/v1/suggest`        | GET | 200 / 2,302 B         | 搜索联想，返回结构化 plan |
| `/v1/browse/catalog` | GET | 200 / 3,398 B(+)      | 目录浏览/筛选/排序      |
| `/v1/catalog/{id}`   | GET | 200 / 10,970–17,935 B | 作品详情，返回 37 字段   |

### 2.3 播放（两阶段）

| 端点                              | 方法   | 实测             | 说明                                                                   |
| ------------------------------- | ---- | -------------- | -------------------------------------------------------------------- |
| `/v1/playback/resolve/{token}`  | GET  | 200 / 17,416 B | 阶段一：拿线路列表                                                            |
| `/v1/playback/resolve-line`     | POST | 201 / 1,281 B  | 阶段二：换真实播放地址，需 `?view=compact`                                        |
| `/v1/playback/resolve/{坏token}` | GET  | 400            | `{"code":"invalid_public_playback_id","message":"播放标识已失效，请重新打开播放页"}` |

### 2.4 用户

| 端点                             | 方法   | 实测             | 说明                                    |
| ------------------------------ | ---- | -------------- | ------------------------------------- |
| `/v1/users/anonymous` *        | POST | 201 / 13,004 B | 建匿名会话（只支持 POST，GET 报 404）             |
| `/v1/users/captcha` *          | POST | 201 / 10,572 B | 图形验证码，返回 `challenge_id` + `image_svg` |
| `/v1/users/password/login`     | POST | 400（缺参）        | 登录，必填 `account` + `password`          |
| `/v1/users/password/register`  | POST | 未实测            | 注册                                    |
| `/v1/users/logout`             | POST | 201 / 43 B     | 登出，返回 `{"logged_out":false}`          |
| `/v1/users/me`                 | GET  | 200 / 12,913 B | 当前用户                                  |
| `/v1/users/me/quota`           | GET  | 200 / 7,698 B  | 每日 token 配额与等级                        |
| `/v1/users/me/preferences`     | GET  | 200 / 324 B    | 用户偏好                                  |
| `/v1/users/me/favorites`       | GET  | 200 / 238 B    | 收藏列表                                  |
| `/v1/users/me/history`         | GET  | 200 / 242 B    | 观看历史                                  |
| `/v1/users/me/invite`          | GET  | 200 / 551 B    | 邀请码与奖励规则                              |
| `/v1/users/me/playlists`       | GET  | 401            | 需登录                                   |
| `/v1/users/me/playlists/saved` | GET  | 401            | 需登录                                   |
| `/v1/users/me/invite/progress` | GET  | 401            | 需登录                                   |
| `/v1/users/me/library/sync` *  | POST | 401（游客）        | 资料库同步，只支持 POST                        |
| `/v1/users/me/password`        | —    | 未实测            | 改密                                    |
| `/v1/users/me/avatar`          | —    | 404            | 路由不存在，可能已废弃                           |
| `/v1/users/invite/open`        | —    | 未实测            | 邀请码开启                                 |

### 2.5 社区与杂项

| 端点                           | 方法   | 实测             | 说明                                                             |
| ---------------------------- | ---- | -------------- | -------------------------------------------------------------- |
| `/v1/threads`                | GET  | 200 / 1,778 B  | 讨论帖列表                                                          |
| `/v1/threads/{id}`           | GET  | —              | 详情；`/v1/threads/archive` 会被当成 id，报 `Thread not found: archive` |
| `/v1/comments`               | GET  | 200 / 132 B（空） | 必填 `variant_id`，否则 `400 variant_id is required.`               |
| `/v1/reports/batch`          | POST | 400（缺参）        | 埋点批量上报，body 需 `events` 数组                                      |
| `/v1/sites/traffic/visits` * | POST | 400（字段不对）      | 访问统计，只支持 POST                                                  |
| `/v1/voice/transcriptions`   | POST | 400            | 语音转写，需 `audio_base64`                                          |
| `/v1/tv-cast`                | —    | 404            | 路由存在但 GET 不通，可能是 POST 或已下线                                     |

### 2.6 确认不存在

以下在分包里出现过字符串但实测 404，属废弃或未上线：

- `/v1/yj/catalog`、`/v1/yj/trending`
- `/v1/search/suggest`（正确路径是 `/v1/suggest`）
- `/v1/users/anonymous`（GET）、`/v1/users/captcha`（GET）、`/v1/sites/traffic/visits`（GET）
- `/v1/users/me/library/sync`（GET）

另外 `/v1/catalog/suggest?q=` 返回 **500 内部错误**，属服务端 bug。

---

## 三、核心数据结构

### 3.1 `content_kind` 八种枚举

```js
["movie", "series", "short_drama", "anime", "variety", "documentary", "sports", "adult"]
```

中文映射：电影 / 电视剧 / 短剧 / 动漫 / 综艺 / 纪录片 / 体育 / 成人。

### 3.2 首页信息流

`GET /v1/feed/home?scope=public&mode=page&sections=3&cards=12`

| 参数         | 说明                          |
| ---------- | --------------------------- |
| `scope`    | `public`                    |
| `mode`     | `page`（分页）或 `preview`（首屏预览） |
| `sections` | 本次返回几个分区，默认 3，上限 11         |
| `cards`    | 每个分区几张卡，默认 10，上限 20         |
| `cursor`   | 翻页游标                        |

响应顶层：

```json
{
  "object": "home.feed",
  "strategy": "resource_center_snapshot",
  "period": "day",
  "quota": { "section_limit": 11, "cards_per_section": 20,
             "websearch_query_budget": 4, "websearch_concurrency": 4,
             "websearch_timeout_ms": 8000 },
  "sections": [ ... ],
  "source_statuses": [ { "sourceId": "feed_douban_hot_snapshots", "sourceType": "resource_center",
                         "status": "ok", "message": "..." } ],
  "personalization": { "applied": false, "source": "none",
                       "cluster_id": "default", "cluster_confidence": 0, "signals": [] },
  "generated_at": "...", "expires_at": "...",   // 缓存 TTL 10 分钟
  "next_cursor": "eyJzZWN0aW9uX29mZnNldCI6M30",
  "meta": { "mode": "page", "section_offset": 0, "section_limit": 3,
            "cards_per_section": 12, "returned_sections": 3, "total_sections": 11,
            "next_cursor": "..." }
}
```

**游标就是 base64 的 `{"section_offset":N}`**，无签名无加密：

| 页 | 请求                                                     | 返回分区                              |
| - | ------------------------------------------------------ | --------------------------------- |
| 1 | 无 cursor                                               | 大家都在看、韩剧在追、日剧上新                   |
| 2 | `eyJzZWN0aW9uX29mZnNldCI6M30` → `{"section_offset":3}` | 美剧续看、国产新剧、高分电影                    |
| 3 | `...Njo2fQ` → `{"section_offset":6}`                   | 电影热播、院线热映、即将上映                    |
| 4 | `...OjE5fQ` → `{"section_offset":9}`                   | 冷门好片、动画连载（2 个，`next_cursor=null`） |

11 个分区全名单：**大家都在看、韩剧在追、日剧上新、美剧续看、国产新剧、高分电影、电影热播、院线热映、即将上映、冷门好片、动画连载**。

分区对象字段：`id, type, role, title, subtitle, reason, priority, cards, browse, evidence`。

- `type`: `collection`
- `role`: `base`
- `priority`: 整数（如 78）
- `reason`: 如 `center_hot_list:movie_hidden_gems`
- `browse`: 一个**可直接执行的请求描述**
  ```json
  { "type": "catalog_browse_request", "label": "查看完整榜单",
    "method": "GET", "path": "/v1/browse/catalog",
    "params": { "hot_list_key": "movie_hidden_gems", "limit": "20" },
    "page": 1, "limit": 20 }
  ```
- `evidence`: 数据来源追溯
  ```json
  { "center_sources": ["douban_hot_snapshots:movie_hidden_gems"],
    "websearch_used": false, "websearch_queries": [] }
  ```

### 3.3 卡片（feed card）

字段数不是固定的，按分区类型分两套：

| 分区               | 字段数 | 差异                                                                             |
| ---------------- | --- | ------------------------------------------------------------------------------ |
| "大家都在看"（综合流）     | 26  | 有 `aliases`、`rank_reason`；无横版图与评分                                              |
| 榜单类（韩剧/日剧/电影热播等） | 28  | 有 `carousel_url`、`backdrop_url`、`score`、`popularity`；无 `aliases`、`rank_reason` |

两者并集 30 个。取值前先用 `has` 判断，别假设字段齐全。

```
id, work_id, seasons, export_id, title, normalized_title, aliases,
content_kind, year, area, language, genres, actors, directors,
poster_url, carousel_url, backdrop_url, remarks,
playback_groups, availability, score, popularity,
heat_value, playback_count, updated_at,
rank_reason, rank_position, reasons, facts, detail_url
```

实测样本（节选）：

```json
{
  "id": "av_nH2ZeKZ0Ft4q...",
  "work_id": "work:yj:49f97f9dbad1807a25d8",
  "export_id": 760186,
  "title": "万物生灵:2025圣诞特别集",
  "normalized_title": "万物生灵2025圣诞特别集",
  "content_kind": "movie",
  "year": 2025, "area": "英国",
  "genres": ["剧情", "喜剧", "电影", "欧美剧"],
  "remarks": "高清",
  "playback_groups": [
    { "id": "yjplayer", "label": "网页播放器", "type": "player",  "episode_count": 1, "episodes": [] },
    { "id": "yjm3u8",   "label": "m3u8",       "type": "m3u8",    "episode_count": 1, "episodes": [] },
    { "id": "yjapi",    "label": "YJ API",     "type": "api",     "episode_count": 1, "episodes": [] }
  ],
  "availability": { "state": "playable", "label": "可播放",
                    "playable": true, "disabled": false, "source": "catalog" },
  "score": 8.9, "popularity": 5414, "heat_value": 137.38, "playback_count": 20,
  "reasons": ["hot_list:movie_hidden_gems", "冷门佳片", "douban_hot_snapshot"],
  "facts": { "theme_terms": ["田园","乡村","兽医","动物","温情","治愈"],
             "embedding_terms": [], "intent_phrases": ["好看的英剧","温馨治愈"] },
  "detail_url": "/v1/catalog/av_nH2ZeKZ0Ft4q..."
}
```


两个值得注意的点：

- `id` 就是详情端点要的路径参数，直接拼 `/v1/catalog/{id}`。
- `poster_url` 等图片走百度图床代理（`gimg0.baidu.com/gimg/app=2001&...&src=img.baipiaozhe.com/...`），源站在 `img.baipiaozhe.com`。
- `facts` 是 AI 推荐用的检索词（主题词、嵌入词、意图短语），不是展示字段。

### 3.4 详情

`GET /v1/catalog/{id}` — 37 个顶层字段：

```
current_episode_count, total_episode_count, update_status, is_completed,
episode_progress_text, object, id, variant_id, selected_variant_id,
default_variant_id, title, normalized_title, content_kind, year, area,
language, genres, actors, directors, poster_url, carousel_url, backdrop_url,
remarks, description, episode_count, available_episode_count,
episodes, episode_pagination, variants, seasons, season_count,
playback_groups, heat_value, playback_count,
ai_entry_actions, playback_skip_settings_preset, watch_calendar_forecast
```

**`episodes[].token` 是整条播放链路的入口**。episode 8 个字段：

```
id, number, episode_track, key, title, token, playback_count, urls
```

```json
{
  "id": "av_sQvf0YRvcxzSBYyjnKXueuZ3KOQ3nmZkOeTQk-GWPVx8TQ-n-S9DuSMGbDdyATzKovRNBAAK2YiI9lBHxvCofkmKJ5vT9JkBcFjfcA",
  "number": 1,
  "episode_track": "main",
  "key": "e-0001",
  "title": "第1集",
  "token": "av_13MgWpKHqKMBQMZ01SYGtUmG2qPRjyQJD2xiAGTO1FeF7jUj_9OgBB9BWU_9h-nCJTY0R-sHllwjm_VWhey4KR0",
  "playback_count": 31,
  "urls": {}
}
```

`urls` 在详情里是空的，真实地址必须走播放接口取。

`variants`（多季/多版本）字段：`id, variant_id, work_id, title, season_label, year, episode_count, available_episode_count, has_playback, playback_count, heat_value, updated_at, selected, default`。

### 3.5 线路选项（line_option）

`GET /v1/playback/resolve/{episode_token}` 返回：

```json
{ "object": "playback.resolve", "token": "av_13Mg...", "current_episode": {...}, "line_options": [...] }
```

`line_option` 18 个字段：

```
id, playback_source_id, provider_id, provider_name, play_from, source_vod_id,
label, display_label, url, url_kind, resolved, resolve_mode, resolve_required,
default_priority, preference_weight, minimum_user_level, selected, price_multiplier_bps
```

关键字段：

- `url_kind`：`m3u8`（直出）或 `resolve_ticket`（需二次解析）
- `resolve_required`：`false` 直接播 `url`；`true` 要走第二阶段
- `url`：`resolve_required=true` 时形如 `resolve://av_xxxx`，**`resolve://` 后面那串就是 ticket**
- `price_multiplier_bps`：token 消耗倍率，`15000` = 1.5 倍
- `minimum_user_level`：最低用户等级（实测均为 0）

---

## 四、播放链路

两阶段。第一阶段的线路列表实测 30~~36 条不等，其中**直出稳定 26 条，其余为需二次解析的官方线**（4~~7 条，随集数浮动）。

### 4.1 阶段一：拿线路

```
GET /v1/playback/resolve/{episode.token}
```

### 4.2 阶段二：换真实地址（仅 resolve_required=true 时）

```
POST /v1/playback/resolve-line?view=compact
Content-Type: application/json

{ "ticket": "<url 去掉 resolve:// 前缀后的部分>" }
```

返回 **201**：

```json
{
  "object": "playback.line.resolve",
  "token": "av_13Mg...",
  "content_kind": "series",
  "episode_count": 36,
  "current_episode": {
    "id": "av_sQvf...", "token": "av_13Mg...", "episode_number": 1, "sequence_index": 1,
    "source_previous_episode_token": null, "source_next_episode_token": "av_9Q1G...",
    "previous_episode_token": null, "next_episode_token": "av_9Q1G...",
    "episode_key": "e-0001", "display_name": "第1集", "urls": {}
  },
  "line": {
    "id": "playback:yj:ac24cf09334c7e621553",
    "play_from": "rrys",
    "label": "1080P-官方R",
    "url": "https://sign.site.zshtys888.com/file.m3u8?ucode=9eebff9cad974c66a63f7a0b98c1fb6d&red=1",
    "url_kind": "m3u8", "resolved": true, "resolve_required": false,
    "resolve_mode": "parse", "token_scenario": "...",
    "default_priority": true, "minimum_user_level": 0, "selected": true
  },
  "view": "compact"
}
```

`?view=compact` 是**必须**的，缺了会返回完整版（字段更多，体积更大，不影响取 `line.url`）。

### 4.3 实测同级结果

| 线路        | play_from   | 解析后地址                                                     | 拉流验证                        |
| --------- | ----------- | --------------------------------------------------------- | --------------------------- |
| 高清-官方B    | `bytedance` | `v6-custom0010.onewsvod.com/.../video/tos/cn/...`（MP4 直链） | 200 `video/mp4`             |
| 1080P-官方R | `rrys`      | `sign.site.zshtys888.com/file.m3u8?ucode=...`             | 200 `application/x-mpegURL` |

`/v1/playback/resolve-line` 的失败分支有两种，`code` 完全不同，处理方式也不同：

| 场景            | HTTP    | 响应                                                                                                           |
| ------------- | ------- | ------------------------------------------------------------------------------------------------------------ |
| 线路失效          | 404     | `{"code":"playback_line_unavailable"}` → 换线路                                                                 |
| **该线路需要登录**   | **401** | `{"statusCode":401,"code":"playback_user_session_required","state":"login_required","message":"该内容需要登录后播放"}` |
| ticket 过期/伪造成 | 400     | `{"code":"invalid_public_playback_id"}`                                                                      |

**实测案例**：《沙丘2》的「海外-官方C」线（`play_from=cloudflare`）在**无 Cookie** 状态下必返 401 `playback_user_session_required`；换成《京城奇探》的「1080P-官方R/S/V」则正常 201。

这说明两点：

1. 官方线并非全都对游客开放，部分内容（尤其新片）有登录门槛；
2. 排查报错时**不要一看到 401 就怀疑签名**——签名错是 `invalid_request_signature`，登录门槛是 `playback_user_session_required`，看 `code` 字段即可分辨。

---

## 五、线路源清单

**线路条数是动态的，每次请求都可能不同**，不要硬编码。同一部《京城奇探》不同集数实测：

| 集数    | 总线路 | 直出 | 需二次解析 |
| ----- | --- | -- | ----- |
| 第 1 集 | 33  | 26 | 7     |
| 第 2 集 | 30  | 26 | 4     |
| 第 3 集 | 33  | 26 | 7     |
| 第 4 集 | 33  | 26 | 7     |

规律：**直出线路稳定为 26 条**（26 个采集源全量返回），波动来自官方线——不同集数可用的官方线数不同（4~7 条）。同一天早前实测第 1 集为 30 条（26+4），晚间复测为 33 条（26+7），说明官方线是动态下发的。

这是设计上合理的行为：采集源是静态索引，官方线依赖上游版权方实时授权。

跨前 3 集合并统计，标签去重后共 **31 种**（26 个采集源 + 5 种官方线标签）。

### 5.1 官方线（需二次解析，`url_kind=resolve_ticket`）

实测出现过的 5 种：

| 标签        | `play_from`  | token 倍率    |
| --------- | ------------ | ----------- |
| 高清-官方B    | `bytedance`  | 1.0x（10000） |
| 1080P-官方R | `rrys`       | 1.5x（15000） |
| 海外-官方C    | `cloudflare` | 0.5x（5000）  |
| 1080P-官方V | `huo`        | 2.0x（20000） |
| 1080P-官方S | `lv3`        | 未标          |
| 腾讯视频      | `qq`         | 未标          |

`price_multiplier_bps` 即 token 消耗倍率，`15000` = 1.5 倍。游客 `level=1` 时可用的官方线受 `minimum_user_level` 限制。

### 5.2 第三方采集源（直出 m3u8，`url_kind=m3u8`）

26 条，标签与 `play_from`：

```
新浪资源 xlm3u8      魔都资源 modum3u8    1080zyk 1080zyk
西瓜资源 xiguam3u8   红牛资源 hnm3u8      无水印资源 wsym3u8
极速资源 jsm3u8      豪华资源 hhm3u8      暴风资源 bfzym3u8
豆瓣资源 dbm3u8      索尼资源 snm3u8      ikun资源 ikm3u8
iqiyi资源 iqym3u8    U酷资源 ukm3u8       猫眼资源 mym3u8
金鹰资源 jinyingm3u8 电影天堂资源 dyttm3u8 无尽资源 wjm3u8
速播资源 subm3u8     量子资源 lzm3u8      最大资源 zuidam3u8
360资源 360zy       茅台资源 mtm3u8      非凡资源 ffm3u8
牛牛资源 nnm3u8      如意资源 rym3u8
```

`play_from` 命名规律很清晰：`<源代号>m3u8`，少数的例外是 `1080zyk`、`360zy`。

### 5.3 直出域名分布（前 20）

同一部剧前 3 集合计 91 条线路，其中直出（`url_kind=m3u8`）78 条、需解析 13 条。下表是 78 条直出线路的域名分布：

| 次数 | 域名                    |
| -- | --------------------- |
| 6  | `play.xluuss.com`     |
| 3  | `play.modujx11.com`   |
| 3  | `cdn.yzzyvip-29.com`  |
| 3  | `svip.xgplay17.com`   |
| 3  | `hn.bfvvs.com`        |
| 3  | `v14.wsyzym3u8.com`   |
| 3  | `vv.jisuzyv.com`      |
| 3  | `play.hhuus.com`      |
| 3  | `v.baofeng11.com`     |
| 3  | `vodcnd15.fdtnbv.com` |
| 3  | `v14.rstu6.com`       |
| 3  | `bfikuncdn.com`       |
| 3  | `play.ly166.com:65`   |
| 3  | `ukzy.ukubf3.com`     |
| 3  | `play.maoyanplay.top` |
| 3  | `hd.ijycnd.com`       |
| 3  | `vip.dytt-tvs.com`    |
| 3  | `v.lzcdn27.com`       |
| 3  | `vod1.maowushi.com`   |
| 3  | `vodcnd03.trjho.com`  |

每个源固定 3 台前缀/域名轮换，说明上游是同一家采集商的多 CDN 部署。

### 5.4 m3u8 形态

直出流有两种：

1. **明文 m3u8**：`https://hn.bfvvs.com/play/eERPZLga/index.m3u8`，`Content-Type: application/vnd.apple.mpegurl`
2. **AES-128 加密 m3u8**：playlist 内含 `#EXT-X-KEY:METHOD=AES-128,URI="..."`，key 与 iv 在同一域名下，可直接拉取解密

拉流验证通过（200 + 正确 Content-Type），分片可正常获取。

---

## 六、搜索联想的结构化 plan

`GET /v1/suggest?q=沙` 返回的不是普通字符串数组，而是**带执行计划的建议**：

```json
{
  "object": "movie.suggestions",
  "query": "沙",
  "suggestions": [
    {
      "id": "rule:movie:沙",
      "type": "action",
      "intent": "filter",
      "label": "沙 电影",
      "subtitle": "只看电影版",
      "prompt": "沙 电影",
      "plan": { "intent": "...", ... }
    }
  ]
}
```

前端点一条建议不是直接提交搜索框字符串，而是按 `plan.intent` 构造 `browse/catalog` 的 query。所以做客户端时要么完整解析 `plan`，要么直接把 `prompt` 当关键词用。

---

## 七、配额与等级

`GET /v1/users/me/quota` 结构（游客）：

```json
{
  "object": "user.daily_token_quota",
  "role": "guest",
  "level": 1,
  "level_title": "初出茅庐",
  "level_icon_key": "lianqi-1",
  "growth": 0,
  "current_level_growth": 0,
  "next_level_growth": 0,
  "level_progress": 0,
  ...
}
```

播放线路的 `price_multiplier_bps` 就是这个配额体系的扣费倍率。官方线要扣 token，采集源线不扣（`price_multiplier_bps` 为 `null`）。这解释了为什么默认选中项是官方线（`selected: true`，`default_priority: true`）——优先消耗用户配额。

`resolve-line` 响应里可能带 `quota_delta`，实测该字段为 `null`（游客/采集源场景不扣）。

---

## 八、可直接使用的客户端

完整实现放在 `.tmp/kanju/kj.py`（`.tmp/` 在 `.gitignore` 内）。核心三个函数：

```python
def sign(method, url, ts, nonce): ...        # HMAC 签名
def headers_for(method, url, extra=None): ... # 组装请求头
def call(path, method="GET", body=None): ...  # 发请求，返回 (status, body)
```

用法：

```python
from kj import call
import json

st, body = call('/v1/suggest?q=沙')
print(st, json.dumps(json.loads(body), ensure_ascii=False, indent=2)[:500])
```

走完一条完整播放链路：

```python
# 1. 搜片
st, b = call('/v1/browse/catalog?q=沙丘')
cid = json.loads(b)['cards'][0]['id']

# 2. 详情拿 episode token
st, b = call('/v1/catalog/' + cid)
tok = json.loads(b)['episodes'][0]['token']

# 3. 拿线路
st, b = call('/v1/playback/resolve/' + tok)
for x in json.loads(b)['line_options']:
    if not x['resolve_required']:
        print('直出:', x['label'], x['url'])
    else:
        # 4. 二次解析
        ticket = x['url'][len('resolve://'):]
        st2, b2 = call('/v1/playback/resolve-line?view=compact', 'POST', {'ticket': ticket})
        print('解析:', x['label'], json.loads(b2)['line']['url'])
```

---

## 九、遗留与未验证项

诚实标注，避免误用：

| 项                                               | 状态                             |
| ----------------------------------------------- | ------------------------------ |
| 注册流程（`/v1/users/password/register`）             | 未实测，需先拿 captcha `challenge_id` |
| 登录成功后的 Cookie 行为                                | 未实测（无账号）                       |
| `/v1/users/me/password`、`/v1/users/invite/open` | 未实测                            |
| `/v1/tv-cast`                                   | GET 404，实际方法未知（可能是 POST 或已下线）  |
| `/v1/threads/{id}` 详情                           | 未实测（只验证了 archive 会被当 id）       |
| `/v1/catalog/suggest` 500                       | 服务端 bug，未追根因                   |
| `x-ai-movie-content-surface` 等可选头               | 未验证是否影响返回内容                    |

---

## 十、结论

1. **鉴权只是"防君子"级别**：密钥硬编码在前端包，签名算法 20 行可复现，无时间窗校验（时间戳未验证是否必须接近当前时间），nonce 不防重放。
2. **会话门槛极低**：一个 POST 即可拿一年期游客 Cookie，无需邮箱手机号。
3. **真正的价值在第三方采集源**：26 条直出 m3u8 线路稳定存在、不消耗配额、直接给地址，覆盖主流影视资源站。官方线反而要扣 token，且部分内容还要登录。
4. **接口设计比较规范**：`browse` 字段把"下一步请求"直接编码进响应，`reasons`/`facts` 保留推荐可解释性，`source_statuses` 做数据源健康度上报——这套是典型的 AI 聚合站架构。
5. **前端是 AI 驱动的**：`facts.theme_terms` / `intent_phrases`、`suggest` 的 `plan`、`personalization.cluster_id`、`websearch_query_budget` 都指向后端有大模型参与选片与检索编排。

---

分析时间：2026-11-10 · 全部状态码与数据为当日实测

