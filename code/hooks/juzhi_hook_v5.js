/*
 * 橘汁 App v5 —— 响应体抓取 + 播放页导航
 * 目标：捕获 /api/proto/v5/drama/getDetail 与 /api/proto/v5/videoUsableUrl 的 protobuf 响应
 */

var TAG = '[JZ5]';
var API_RE = /hzhcbkj|juziapp|ncasdh/;

function hexOf(b, max) {
    try {
        var s = '', n = Math.min(b.length, max || 400);
        for (var i = 0; i < n; i++) {
            var v = (b[i] & 0xff).toString(16);
            s += (v.length < 2 ? '0' : '') + v;
        }
        return s;
    } catch (e) { return '<hexfail>'; }
}

function asciiOf(b, max) {
    try {
        var s = '', n = Math.min(b.length, max || 200);
        for (var i = 0; i < n; i++) {
            var c = b[i] & 0xff;
            s += (c >= 32 && c < 127) ? String.fromCharCode(c) : '.';
        }
        return s;
    } catch (e) { return '<fail>'; }
}

function jstr(s) { try { return s === null ? 'null' : String(s); } catch (e) { return '<fail>'; } }

function appContext() {
    try {
        var ctx = Java.use('android.app.ActivityThread').currentApplication();
        if (ctx !== null) return ctx;
    } catch (e) { }
    return null;
}

setTimeout(function () {
    Java.perform(function () {
        console.log(TAG + ' ===== v5 installed =====');

        /* --- 崩溃兜底 --- */
        try {
            var CtxHolder = Java.use('o00OoO.OooOO0');
            CtxHolder.OooO00o.implementation = function () {
                var r = this.OooO00o();
                if (r === null) { var c = appContext(); if (c !== null) return c; }
                return r;
            };
            var DevUtil = Java.use('o00OoO.OooO0O0');
            DevUtil.OoooOO0.implementation = function (ctx) {
                if (ctx === null) return Java.use('java.lang.Boolean').valueOf(false);
                try { return this.OoooOO0(ctx); } catch (e) { return Java.use('java.lang.Boolean').valueOf(false); }
            };
            console.log(TAG + ' OK fix');
        } catch (e) { console.log(TAG + ' FAIL fix: ' + e); }

        /* --- 响应体抓取：RealInterceptorChain --- */
        var seen = {};
        try {
            var RIC = Java.use('okhttp3.internal.http.RealInterceptorChain');
            var hit = false;
            RIC.proceed.overloads.forEach(function (ov) {
                var at = ov.argumentTypes;
                if (at.length !== 1) return;
                if (at[0].className !== 'okhttp3.Request') return;
                ov.implementation = function (req) {
                    var resp = ov.call(this, req);
                    try {
                        var url = req.url().toString();
                        if (!API_RE.test(url)) return resp;
                        var code = resp.code();
                        console.log(TAG + ' [RESP] ' + code + ' ' + url);

                        var peek = resp.peekBody(2 * 1024 * 1024);
                        if (peek === null) return resp;
                        var bs = peek.bytes();
                        if (bs === null || bs.length === 0) return resp;

                        var key = url.split('?')[0];
                        var n = (seen[key] = (seen[key] || 0) + 1);

                        console.log(TAG + '   len=' + bs.length + ' ct=' + jstr(resp.header('Content-Type')));
                        console.log(TAG + '   HEX=' + hexOf(bs, 700));
                        console.log(TAG + '   ASC=' + asciiOf(bs, 700));

                        // 提取响应内所有 http(s) 链接
                        var txt = asciiOf(bs, 8000);
                        var m = txt.match(/https?:\/\/[ -~]{6,180}/g);
                        if (m) {
                            var uniq = {};
                            m.forEach(function (u) {
                                u = u.replace(/[^ -~]+$/, '');
                                if (!uniq[u]) { uniq[u] = 1; console.log(TAG + '   URL> ' + u); }
                            });
                        }
                    } catch (e) { console.log(TAG + ' [RESP-ERR] ' + e); }
                    return resp;
                };
                hit = true;
            });
            console.log(TAG + ' OK chain-hook=' + hit);
        } catch (e) { console.log(TAG + ' FAIL chain: ' + e); }

        /* --- proto 解析器入参（结构化解码用） --- */
        try {
            var P = Java.use('o00Oo0o0.o0ooOOo');
            var ms = P.class.getDeclaredMethods(), n2 = 0;
            for (var i = 0; i < ms.length; i++) {
                var mn = ms[i].getName();
                if (mn.indexOf('Ooo') !== 0) continue;
                (function (mname) {
                    try {
                        var ovs = P[mname].overloads;
                        for (var j = 0; j < ovs.length; j++) {
                            var at = ovs[j].argumentTypes;
                            if (at.length === 1 && at[0].className === 'com.google.protobuf.ByteString') {
                                ovs[j].implementation = function (bs) {
                                    try {
                                        var arr = bs.toByteArray();
                                        if (arr.length > 60) {
                                            console.log(TAG + ' [PROTO] ' + mname + ' len=' + arr.length);
                                            console.log(TAG + '   PASC=' + asciiOf(arr, 900));
                                        }
                                    } catch (e) { }
                                    return ovs[j].apply(this, arguments);
                                };
                                n2++;
                            }
                        }
                    } catch (e) { }
                })(mn);
            }
            console.log(TAG + ' OK proto=' + n2);
        } catch (e) { console.log(TAG + ' FAIL proto: ' + e); }

        /* --- 播放器起播地址 --- */
        ['com.tencent.thumbplayer', 'tv.danmaku.ijk.media'].forEach(function (pkg) {
            try {
                var cls = Java.enumerateLoadedClassesSync().filter(function (c) {
                    return c.indexOf(pkg) === 0 && /Player|Media/.test(c);
                });
                console.log(TAG + ' loaded ' + pkg + '=' + cls.length);
            } catch (e) { }
        });

        console.log(TAG + ' ===== ready =====');
    });
}, 0);