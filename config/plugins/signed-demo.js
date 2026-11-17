// 签名/加密类源的插件模板。
//
// ============================================================
// 这个文件解决什么问题
// ============================================================
//
// 之前的评估结论是「签名类源不能插件化，只能内置硬编码」，理由是
// QuickJS 没有 crypto、没有二进制能力。那个结论在**注入宿主能力之后
// 就不再成立**了：
//
//   host.md5 / sha1 / sha256 / hmac   —— 摘要与 HMAC 签名
//   host.aesEcbEncrypt / Decrypt      —— AES-ECB（橘汁那类）
//   host.aesCbcEncrypt / Decrypt      —— AES-CBC
//   host.rsaEncrypt                   —— RSA 公钥加密（PKCS#1 v1.5）
//   host.b64e / b64d / hex / unhex    —— 编码转换
//   host.xml2json                    —— XML 站
//   host.randomHex / randomAlnum      —— nonce
//
// 这些全部是**同步**的（实测单次往返 0.15ms），所以脚本依然是
// 普通同步函数，不需要 async。
//
// ============================================================
// 关键认知：公钥加密 ≠ 签名
// ============================================================
//
// 橘汁协议的注释写的是：
//     sig = Base64_NO_WRAP(RSA/ECB/PKCS1(ts + random16 + vApp))
//
// 名字叫 `sig`，但**实现是公钥加密**：客户端拿公钥加密一段拼接串，
// 服务端用私钥解出来校验。
//
// 这个区别决定了一切：
//   - 真签名（要私钥）→ 客户端做不了，私钥会泄漏
//   - 公钥加密（要公钥）→ 完全可行，公钥本来就在 APK 里
//
// 所以「把签名逻辑放进公开仓库的脚本」这件事是成立的：脚本里放的是
// 公钥，不是私钥。
//
// ============================================================
// 用法：在 index.json 里加一行 signEntry
// ============================================================
//
//   {
//     "id": "signed_demo",
//     "script": "config/plugins/signed-demo.js",
//     "signEntry": "sign",          ← 就是这一行
//     "vars": { "appVer": "1.0.0" },
//     ...
//   }
//
// 配上之后，宿主在**每次发请求前**调用 sign(req)，把返回值合并进
// 请求再发出去。没配就完全不调用——所以这个脚本对普通源无副作用。
//
// ============================================================
// 签名函数的输入输出契约
// ============================================================
//
//   function sign(req) → { headers?, query?, body? }
//
//   req = {
//     url, method,          当前要发的请求（已按清单展开好）
//     query: {...},         URL 上的查询参数
//     headers: {...},       已有的请求头
//     body,                 POST 体（GET 时是空串）
//     vars,                 清单里该源的 vars
//     ctx: { baseUrl, sourceId }
//   }
//
// **只返回要改的部分**，没返回的字段宿主一律不动。
// 宿主完全不理解你的协议，它只做「把返回的东西盖上去」。
//
// ============================================================
// 硬性约束（同其它插件）
// ============================================================
//
// 1. 必须同步。返回 Promise 会被拒。
// 2. 不能写死循环。
// 3. **不能改 Host / Cookie / Authorization**。这三个会被宿主直接
//    拒绝并让整个请求作废——它们是劫持与凭证注入的入口。
// 4. host 调用有次数上限（5000 次/次调用）。别在循环里狂调。

// ============================================================
// 下面是一个**可运行的最小示例**：HMAC-SHA256 签名
// ============================================================
//
// 它演示了完整的流程，且不依赖任何外部密钥——用的密钥来自
// 清单的 vars。真实接入时把 SECRET 换成抓包得到的那串即可。

/**
 * 取 vars 里的值，带兜底。
 *
 * `vars` 在 req 的**顶层**（不是 req.ctx.vars）。早期版本的示例读的是
 * `req.ctx.vars`，拿到的是 undefined，于是密钥永远为空、`sign()` 走
 * 「没配密钥」分支返回 `{}`，表现是「一个签名头都没发出去」。
 * 这个错极难从现象反推，所以这里同时认两个位置。
 */
function v(req, key, dflt) {
  var bag = req && req.vars ? req.vars : null;
  if (!bag && req && req.ctx && req.ctx.vars) bag = req.ctx.vars;
  if (bag && bag[key] !== undefined && bag[key] !== null) {
    return String(bag[key]);
  }
  return dflt === undefined ? '' : dflt;
}

/**
 * 从完整 URL 里取出「路径 + 查询」，丢掉协议和主机。
 *
 * ## 为什么签名里不能包含主机名
 *
 * 两个原因，第二个是致命的：
 *
 *   1. **服务端通常只签 path**。它看到的是 `GET /api/...?a=1`，
 *      拿不到（也不该信任）`Host` 里写的东西。客户端如果签了
 *      `http://host/api/...`，两边算出来的串必然不同。
 *
 *   2. **采集站换域名是常态**。如果主机名进了待签串，那么源站
 *      从 `a.com` 换到 `b.com` 的当天，所有用户的请求会瞬间全部
 *      签名失效——而且现象是「源昨天好好的，今天全挂」，很难
 *      联想到是签名把域名签进去了。
 *
 * 所以这里只取 `path?query`。`/api/x?a=1` 这种形态两边的认知一致。
 */
function pathOf(url) {
  var u = String(url);

  // 去掉 `http://` / `https://`
  var schemeAt = u.indexOf('://');
  if (schemeAt >= 0) u = u.substring(schemeAt + 3);

  // 去掉主机部分（第一个 `/` 之前都是主机）
  var slashAt = u.indexOf('/');
  if (slashAt >= 0) {
    u = u.substring(slashAt);
  } else {
    // 连斜杠都没有说明只有主机（`http://x.com`），路径按 `/` 算
    u = '/';
  }

  // 去掉 `?` 之后的部分：query 由调用方按排序后重新拼，
  // 直接用原串会有「参数顺序不同导致签名不同」的问题
  var qAt = u.indexOf('?');
  if (qAt >= 0) u = u.substring(0, qAt);

  return u;
}

/**
 * 签名钩子：给每个请求加时间戳 + nonce + HMAC 签名头。
 *
 * 典型的「服务端校验三件事」：
 *   1. 时间戳没过期（防重放）
 *   2. nonce 没用过（防重放）
 *   3. 签名对得上（防篡改）
 *
 * 这三样正好是 sign() 能做到的事，也是纯模板展开做不到的事。
 */
function sign(req) {
  var secret = v(req, 'secret', '');

  // 没配密钥时**不打签名头**，而不是打一个错的。
  // 打错的比不打更难排查：服务端只会返回 401，看不出是密钥没配。
  if (secret === '') return {};

  var ts = String(new Date().getTime());       // 毫秒时间戳
  var nonce = host.randomAlnum(16);            // 16 位字母数字

  // 待签串的拼法必须和服务端完全一致。这里用最常见的形态：
  //   路径 + 排序后的 query + 时间戳 + nonce
  //
  // 为什么 query 要排序：JS 对象的键序在不同引擎下不保证一致，
  // 而不排序会导致「同样的请求算出不同签名」。服务端只要也按
  // 字典序排，两边就能对上。
  var keys = [];
  for (var k in req.query) keys.push(k);
  keys.sort();
  var parts = [];
  for (var i = 0; i < keys.length; i++) {
    parts.push(keys[i] + '=' + req.query[keys[i]]);
  }

  var toSign = pathOf(req.url) + '?' + parts.join('&') + ts + nonce;

  var sig = host.hmac('sha256', secret, toSign);

  return {
    headers: {
      'x-timestamp': ts,
      'x-nonce': nonce,
      'x-sign': sig
    }
  };
}

// ============================================================
// 附：另外三种常见签名的写法（照抄改改就能用）
// ============================================================
//
// ---- ① AES-256-ECB 加密请求体（橘汁那类）----
//
//   function signAes(req) {
//     var key = v(req, 'safeCode', '');
//     // 明文 = 排序后的 k=v&k=v + 时间戳
//     var plain = buildQuery(req.query) + new Date().getTime();
//     var enc = host.aesEcbEncrypt({ key: key, plain: plain });
//     // 前面拼 8 位随机串，再切成两半分别放（橘汁就是这么干的）
//     var merged = host.randomAlnum(8) + enc;
//     return {
//       query: { enc1: merged.substring(0, 20), enc2: merged.substring(20) },
//       headers: { 'x-ts': String(new Date().getTime()) }
//     };
//   }
//
// ---- ② RSA 公钥加密签名（sig 那类）----
//
//   function signRsa(req) {
//     var n = v(req, 'rsaN', '');        // 模数（hex）
//     var e = v(req, 'rsaE', '65537');
//     var ts = String(new Date().getTime());
//     var rnd = host.randomAlnum(16);
//     var ver = v(req, 'appVer', '1.0.0');
//
//     // 注意顺序：ts + random16 + vApp，拼错服务端解出来就是乱的
//     var sig = host.rsaEncrypt({ nHex: n, e: e, data: ts + rnd + ver });
//
//     // 另一路：AES 加密同样内容，切成前 8 / 后段
//     var secret = v(req, 'safeSecret', '');
//     var sigA = host.aesEcbEncrypt({ key: secret, plain: ts + rnd });
//     var half = Math.floor(sigA.length / 2);
//
//     return {
//       query: {
//         sig: sig,
//         sig2: sigA.substring(0, 8),
//         sig3: sigA.substring(8)
//       }
//     };
//   }
//
// ---- ③ 只加静态请求头（最简单）----
//
//   function signHeader(req) {
//     return {
//       headers: {
//         'Referer': v(req, 'referer', 'https://example.com/'),
//         'Origin': req.ctx.baseUrl
//       }
//     };
//   }
//
// 静态头其实也能在清单的 defaultHeaders 里写。放这里唯一的理由是
// 它需要**按请求变化**（比如按 id 算出对应页面的 Referer）。