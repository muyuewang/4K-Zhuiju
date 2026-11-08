/*
 * 橘汁 App v6 —— 完整响应体落盘
 * 只做一件事：把 hzhcbkj 域名的 protobuf 响应完整 dump 成 hex 行，供离线解析
 */

var TAG = '[JZ6]';
var API_RE = /hzhcbkj/;

function hexOf(b) {
    try {
        var s = '';
        for (var i = 0; i < b.length; i++) {
            var v = (b[i] & 0xff).toString(16);
            s += (v.length < 2 ? '0' : '') + v;
        }
        return s;
    } catch (e) { return ''; }
}

function appContext() {
    try {
        var ctx = Java.use('android.app.ActivityThread').currentApplication();
        if (ctx !== null) return ctx;
    } catch (e) { }
    return null;
}

setTimeout(function () {
    Java.perform(function () {
        console.log(TAG + ' ===== v6 installed =====');

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

        try {
            var RIC = Java.use('okhttp3.internal.http.RealInterceptorChain');
            RIC.proceed.overloads.forEach(function (ov) {
                var at = ov.argumentTypes;
                if (at.length !== 1 || at[0].className !== 'okhttp3.Request') return;
                ov.implementation = function (req) {
                    var resp = ov.call(this, req);
                    try {
                        var url = req.url().toString();
                        if (!API_RE.test(url)) return resp;
                        var peek = resp.peekBody(8 * 1024 * 1024);
                        if (peek === null) return resp;
                        var bs = peek.bytes();
                        if (bs === null || bs.length < 200) return resp;

                        console.log(TAG + ' BODY-BEGIN ' + url.split('?')[0] + ' len=' + bs.length);
                        var full = hexOf(bs);
                        var step = 3000;
                        for (var i = 0; i < full.length; i += step) {
                            console.log(TAG + ' H ' + (i / 2) + ' ' + full.substring(i, i + step));
                        }
                        console.log(TAG + ' BODY-END');
                    } catch (e) { console.log(TAG + ' ERR ' + e); }
                    return resp;
                };
            });
            console.log(TAG + ' OK chain');
        } catch (e) { console.log(TAG + ' FAIL chain: ' + e); }

        console.log(TAG + ' ===== ready =====');
    });
}, 0);