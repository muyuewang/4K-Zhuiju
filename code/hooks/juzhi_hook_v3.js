/*
 * 橘汁 App (com.asjdhjhd.mgd.p3) 动态取证 v3
 * 新增：拦截 BaseNativeJNI.method01/method02 入参（明文 JSON）+ 返回值（密文）
 * 新增：拦截 o00O0000.OooO0O0() 返回的最终 Map
 * 保留：v2 的 Context 崩溃兜底、AES/RSA 密钥、OkHttp、proto
 */

var TAG = '[JUZHI]';

function hexOf(b) {
    try {
        var s = '';
        for (var i = 0; i < b.length; i++) {
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
    } catch (e) { return '<asciifail>'; }
}

function jstr(s) { try { return s === null ? 'null' : String(s); } catch (e) { return '<fail>'; } }

function appContext() {
    try {
        var AT = Java.use('android.app.ActivityThread');
        var ctx = AT.currentApplication();
        if (ctx !== null) return ctx;
    } catch (e) { }
    try {
        var Act = Java.use('android.app.ActivityThread');
        var cur = Act.currentActivityThread();
        if (cur !== null) {
            var app = cur.getApplication();
            if (app !== null) return app;
        }
    } catch (e) { }
    return null;
}

function dumpStack(tag) {
    try {
        var Log = Java.use('android.util.Log');
        var ex = Java.use('java.lang.Exception').$new();
        var st = Log.getStackTraceString(ex);
        console.log(tag + ' STACK ' + jstr(st).substring(0, 900));
    } catch (e) { }
}

setTimeout(function () {
    Java.perform(function () {
        console.log(TAG + ' ===== v3 hook installed =====');

        /* ===== 0. 崩溃修复：Context 兜底（保留 v2） ===== */
        try {
            var CtxHolder = Java.use('o00OoO.OooOO0');
            CtxHolder.OooO00o.implementation = function () {
                var r = this.OooO00o();
                if (r === null) {
                    var c = appContext();
                    if (c !== null) { return c; }
                }
                return r;
            };
            console.log(TAG + ' OK  fix ctx');
        } catch (e) { console.log(TAG + ' FAIL fix ctx: ' + e); }

        try {
            var DevUtil = Java.use('o00OoO.OooO0O0');
            DevUtil.OoooOO0.implementation = function (ctx) {
                if (ctx === null) { return Java.use('java.lang.Boolean').valueOf(false); }
                try { return this.OoooOO0(ctx); } catch (e) { return Java.use('java.lang.Boolean').valueOf(false); }
            };
            console.log(TAG + ' OK  fix NPE');
        } catch (e) { console.log(TAG + ' FAIL fix NPE: ' + e); }

        /* ===== 1. 核心：native 加密入口 ===== */
        try {
            var N = Java.use('com.hive.nativec.BaseNativeJNI');
            ['method01', 'method02'].forEach(function (mn) {
                try {
                    N[mn].implementation = function (s) {
                        console.log(TAG + ' >>>>> [' + mn + '-IN] len=' + (s === null ? -1 : String(s).length));
                        console.log(TAG + ' [PLAINTEXT] ' + jstr(s));
                        var r;
                        try {
                            r = this[mn](s);
                        } catch (e) {
                            console.log(TAG + ' [ERR] ' + mn + ' threw: ' + e);
                            throw e;
                        }
                        console.log(TAG + ' <<<<< [' + mn + '-OUT] len=' + (r === null ? -1 : String(r).length));
                        console.log(TAG + ' [CIPHERTEXT] ' + jstr(r));
                        return r;
                    };
                    console.log(TAG + ' OK  hook BaseNativeJNI.' + mn);
                } catch (e) { console.log(TAG + ' FAIL ' + mn + ': ' + e); }
            });

            try {
                N.getAppSignature.implementation = function () {
                    var r = this.getAppSignature();
                    console.log(TAG + ' [APP-SIG] ' + jstr(r));
                    return r;
                };
                console.log(TAG + ' OK  hook getAppSignature');
            } catch (e) { console.log(TAG + ' FAIL getAppSignature: ' + e); }

        } catch (e) { console.log(TAG + ' FAIL BaseNativeJNI: ' + e); }

        /* ===== 2. 参数聚合器：最终 Map ===== */
        try {
            var PU = Java.use('o00O0oo.o00O0000');
            PU.OooO0O0.implementation = function () {
                var r = this.OooO0O0();
                try {
                    console.log(TAG + ' [PUBLIC-MAP] keys=' + r.keySet().toString());
                    console.log(TAG + ' [PUBLIC-MAP-JSON] ' + jstr(r.toString()));
                } catch (e) { console.log(TAG + ' [PUBLIC-MAP] err ' + e); }
                return r;
            };
            PU.OooO00o.implementation = function () {
                console.log(TAG + ' [PUBLIC-BUILD] OooO00o() 触发');
                return this.OooO00o();
            };
            console.log(TAG + ' OK  hook o00O0000');
        } catch (e) { console.log(TAG + ' FAIL o00O0000: ' + e); }

        /* ===== 3. 加密开关 EngineerConfig ===== */
        try {
            var EC = Java.use('o00O00OO.OooOOO');
            EC.OooO0O0.implementation = function () {
                var r = this.OooO0O0();
                try {
                    console.log(TAG + ' [ENGINEER] encryptFlag(f69878OooOO0)=' + r.f69878OooOO0.value);
                } catch (e) { }
                return r;
            };
            console.log(TAG + ' OK  hook EngineerConfig');
        } catch (e) { console.log(TAG + ' FAIL EngineerConfig: ' + e); }

        /* ===== 4. 拦截器链路 ===== */
        try {
            var I1 = Java.use('o00O0oo.o0O0ooO');
            I1.intercept.implementation = function (chain) {
                try {
                    console.log(TAG + ' [INTERCEPT-1] ' + chain.request().url().toString());
                    var h = chain.request().headers();
                    for (var i = 0; i < h.size(); i++) {
                        console.log(TAG + '        hdr ' + h.name(i) + ': ' + h.value(i));
                    }
                } catch (e) { }
                return this.intercept(chain);
            };
            console.log(TAG + ' OK  hook DataPublicParamsInterceptor');
        } catch (e) { console.log(TAG + ' FAIL interceptor: ' + e); }

        /* ===== 5. AES 密钥（保留） ===== */
        try {
            var SKS = Java.use('javax.crypto.spec.SecretKeySpec');
            SKS.$init.overload('[B', 'java.lang.String').implementation = function (k, alg) {
                console.log(TAG + ' [AES-KEY] alg=' + jstr(alg) + ' len=' + k.length + ' ascii=' + asciiOf(k));
                return this.$init(k, alg);
            };
            console.log(TAG + ' OK  SecretKeySpec');
        } catch (e) { console.log(TAG + ' FAIL SecretKeySpec: ' + e); }

        /* ===== 6. 签名注入点（保留） ===== */
        try {
            var H = Java.use('o00O.OooO00o');
            H.OooOOO.overload('java.lang.String', 'java.lang.String').implementation = function (a, b) {
                console.log(TAG + ' [SET-KEY] secretKey=' + jstr(a) + ' safeCode=' + jstr(b));
                return this.OooOOO(a, b);
            };
            H.OooOOO0.overload('java.lang.String').implementation = function (a) {
                console.log(TAG + ' [SET-PUBKEY] ' + jstr(a));
                return this.OooOOO0(a);
            };
            H.OooOO0.overload('java.lang.String').implementation = function (a) {
                console.log(TAG + ' [SECURE-REQ-IN] ' + jstr(a));
                var r = this.OooOO0(a);
                console.log(TAG + ' [SECURE-REQ-OUT] ' + jstr(r));
                return r;
            };
            console.log(TAG + ' OK  o00O.OooO00o');
        } catch (e) { console.log(TAG + ' FAIL o00O.OooO00o: ' + e); }

        /* ===== 7. OkHttp 请求（保留，精简） ===== */
        try {
            var RB = Java.use('okhttp3.Request$Builder');
            RB.build.implementation = function () {
                var req = this.build();
                try {
                    var u = req.url().toString();
                    console.log(TAG + ' [HTTP] ' + req.method() + ' ' + u);
                    var h = req.headers();
                    for (var i = 0; i < h.size(); i++) {
                        var v = jstr(h.value(i));
                        if (h.name(i) === 'publicParams') {
                            console.log(TAG + '        hdr publicParams(len=' + v.length + '): ' + v);
                        } else {
                            console.log(TAG + '        hdr ' + h.name(i) + ': ' + (v.length > 120 ? v.substring(0, 120) + '...' : v));
                        }
                    }
                } catch (e) { }
                return req;
            };
            console.log(TAG + ' OK  OkHttp');
        } catch (e) { console.log(TAG + ' FAIL OkHttp: ' + e); }

        console.log(TAG + ' ===== all hooks ready =====');
    });
}, 0);