/*
 * 橘汁 App (com.asjdhjhd.mgd.p3) 动态取证 v2
 * 修复：o00OoO.OooO0O0.OoooOO0 的 Context 空指针崩溃
 * 修复：proto 解析类真实包名 o00Oo0o0.o0ooOOo
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

setTimeout(function () {
    Java.perform(function () {
        console.log(TAG + ' ===== v2 hook installed =====');

        /* ===== 0. 崩溃修复：Context 兜底 ===== */
        try {
            var CtxHolder = Java.use('o00OoO.OooOO0');
            CtxHolder.OooO00o.implementation = function () {
                var r = this.OooO00o();
                if (r === null) {
                    var c = appContext();
                    if (c !== null) {
                        console.log(TAG + ' [FIX-CTX] OooOO0.OooO00o 返回 null，已用 Application 兜底');
                        return c;
                    }
                    console.log(TAG + ' [FIX-CTX] 兜底失败，仍为 null');
                }
                return r;
            };
            console.log(TAG + ' OK  fix o00OoO.OooOO0.OooO00o');
        } catch (e) { console.log(TAG + ' FAIL fix ctx-holder: ' + e); }

        try {
            var DevUtil = Java.use('o00OoO.OooO0O0');
            DevUtil.OoooOO0.implementation = function (ctx) {
                if (ctx === null) {
                    console.log(TAG + ' [FIX-NPE] OoooOO0(null) 已拦截，返回 false');
                    return Java.use('java.lang.Boolean').valueOf(false);
                }
                try {
                    return this.OoooOO0(ctx);
                } catch (e) {
                    return Java.use('java.lang.Boolean').valueOf(false);
                }
            };
            console.log(TAG + ' OK  fix o00OoO.OooO0O0.OoooOO0');
        } catch (e) { console.log(TAG + ' FAIL fix NPE: ' + e); }

        /* ===== 1. AES 密钥 ===== */
        try {
            var SKS = Java.use('javax.crypto.spec.SecretKeySpec');
            SKS.$init.overload('[B', 'java.lang.String').implementation = function (k, alg) {
                console.log(TAG + ' [AES-KEY] alg=' + jstr(alg) + ' len=' + k.length + ' ascii=' + asciiOf(k));
                return this.$init(k, alg);
            };
            console.log(TAG + ' OK  SecretKeySpec');
        } catch (e) { console.log(TAG + ' FAIL SecretKeySpec: ' + e); }

        /* ===== 2. Cipher 加解密 ===== */
        try {
            var Cipher = Java.use('javax.crypto.Cipher');
            Cipher.doFinal.overload('[B').implementation = function (a) {
                try {
                    console.log(TAG + ' [CIPHER] ' + this.getAlgorithm() + ' in=' + a.length +
                        ' txt=' + asciiOf(a, 400));
                } catch (e) { }
                var r = this.doFinal(a);
                try {
                    console.log(TAG + ' [CIPHER-OUT] b64=' + Java.use('android.util.Base64')
                        .encodeToString(r, 2));
                } catch (e) { }
                return r;
            };
            console.log(TAG + ' OK  Cipher');
        } catch (e) { console.log(TAG + ' FAIL Cipher: ' + e); }

        /* ===== 3. RSA 公钥 ===== */
        try {
            var KF = Java.use('java.security.KeyFactory');
            KF.generatePublic.overload('java.security.spec.KeySpec').implementation = function (spec) {
                var r = this.generatePublic(spec);
                try {
                    console.log(TAG + ' [RSA-PUB] alg=' + r.getAlgorithm() + ' b64=' +
                        Java.use('android.util.Base64').encodeToString(r.getEncoded(), 0));
                } catch (e) { }
                return r;
            };
            KF.generatePrivate.overload('java.security.spec.KeySpec').implementation = function (spec) {
                var r = this.generatePrivate(spec);
                console.log(TAG + ' [RSA-PRIV] alg=' + r.getAlgorithm());
                return r;
            };
            console.log(TAG + ' OK  KeyFactory');
        } catch (e) { console.log(TAG + ' FAIL KeyFactory: ' + e); }

        /* ===== 4. 目标类：密钥注入与签名 ===== */
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
                return this.OooOO0(a);
            };
            H.OooO00o.overload('java.util.Map').implementation = function (m) {
                try { console.log(TAG + ' [SIGN-IN] ' + jstr(m.toString())); } catch (e) { }
                var r = this.OooO00o(m);
                try { console.log(TAG + ' [SIGN-OUT] ' + jstr(m.toString())); } catch (e) { }
                return r;
            };
            console.log(TAG + ' OK  o00O.OooO00o');
        } catch (e) { console.log(TAG + ' FAIL o00O.OooO00o: ' + e); }

        /* ===== 5. OkHttp 请求 ===== */
        try {
            var RB = Java.use('okhttp3.Request$Builder');
            RB.build.implementation = function () {
                var req = this.build();
                try {
                    var u = req.url().toString();
                    console.log(TAG + ' [HTTP] ' + req.method() + ' ' + u);
                    var h = req.headers();
                    for (var i = 0; i < h.size(); i++) {
                        console.log(TAG + '        hdr ' + h.name(i) + ': ' + h.value(i));
                    }
                } catch (e) { }
                return req;
            };
            var RC = Java.use('okhttp3.Response');
            RC.toString.implementation = function () {
                try {
                    var s = this.toString();
                    console.log(TAG + ' [HTTP-RESP] ' + jstr(s).substring(0, 160));
                    return s;
                } catch (e) { return this.toString(); }
            };
            console.log(TAG + ' OK  OkHttp');
        } catch (e) { console.log(TAG + ' FAIL OkHttp: ' + e); }

        /* ===== 6. protobuf 解析（正确包名 o00Oo0o0.o0ooOOo） ===== */
        try {
            var P = Java.use('o00Oo0o0.o0ooOOo');
            var ms = P.class.getDeclaredMethods();
            var n = 0;
            for (var i = 0; i < ms.length; i++) {
                var mn = ms[i].getName();
                if (mn.indexOf('Ooo') !== 0) continue;
                try {
                    (function (mname) {
                        var ovs = P[mname].overloads;
                        for (var j = 0; j < ovs.length; j++) {
                            var at = ovs[j].argumentTypes;
                            if (at.length === 1 && at[0].className === 'com.google.protobuf.ByteString') {
                                ovs[j].implementation = function (bs) {
                                    try {
                                        var arr = bs.toByteArray();
                                        console.log(TAG + ' [PROTO] ' + mname + ' len=' + arr.length +
                                            ' hex=' + hexOf(arr).substring(0, 240));
                                    } catch (e) { }
                                    return ovs[j].apply(this, arguments);
                                };
                                n++;
                            }
                        }
                    })(mn);
                } catch (e) { }
            }
            console.log(TAG + ' OK  proto hooked=' + n);
        } catch (e) { console.log(TAG + ' FAIL proto: ' + e); }

        console.log(TAG + ' ===== all hooks ready =====');
    });
}, 0);