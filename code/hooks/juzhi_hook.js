/*
 * 橘汁 App (com.asjdhjhd.mgd.p3) 动态取证脚本
 * 目标：抓取 AES 密钥、RSA 公钥、SecureRequest 明文、API 请求/响应
 * 运行：frida -H 127.0.0.1:27042 -f com.asjdhjhd.mgd.p3 -l juzhi_hook.js
 */

var TAG = '[JUZHI]';

function hexOf(bytes) {
    try {
        var s = '';
        for (var i = 0; i < bytes.length; i++) {
            var v = (bytes[i] & 0xff).toString(16);
            s += (v.length < 2 ? '0' : '') + v;
        }
        return s;
    } catch (e) { return '<hex-fail>'; }
}

function asciiOf(bytes, max) {
    try {
        var s = '';
        var n = Math.min(bytes.length, max || 200);
        for (var i = 0; i < n; i++) {
            var c = bytes[i] & 0xff;
            s += (c >= 32 && c < 127) ? String.fromCharCode(c) : '.';
        }
        return s;
    } catch (e) { return '<ascii-fail>'; }
}

function jstr(s) {
    try { return s === null ? 'null' : String(s); } catch (e) { return '<fail>'; }
}

setTimeout(function () {
    Java.perform(function () {

        console.log(TAG + ' ===== hook installed =====');

        /* ---------- 1. AES 密钥（SecretKeySpec 构造） ---------- */
        try {
            var SKS = Java.use('javax.crypto.spec.SecretKeySpec');
            SKS.$init.overload('[B', 'java.lang.String').implementation = function (k, alg) {
                console.log(TAG + ' [AES-KEY] alg=' + jstr(alg) + ' len=' + k.length +
                    ' ascii=' + asciiOf(k) + ' hex=' + hexOf(k));
                return this.$init(k, alg);
            };
            SKS.$init.overload('[B', 'int', 'int', 'java.lang.String').implementation = function (k, o, l, alg) {
                console.log(TAG + ' [AES-KEY*] alg=' + jstr(alg) + ' off=' + o + ' len=' + l +
                    ' ascii=' + asciiOf(k) + ' hex=' + hexOf(k));
                return this.$init(k, o, l, alg);
            };
            console.log(TAG + ' OK  SecretKeySpec');
        } catch (e) { console.log(TAG + ' FAIL SecretKeySpec: ' + e); }

        /* ---------- 2. Cipher 加解密明文 ---------- */
        try {
            var Cipher = Java.use('javax.crypto.Cipher');
            var dumpCipher = function (label, self, input) {
                try {
                    var mode = self.getAlgorithm();
                    var txt = '';
                    try { txt = Java.use('java.lang.String').$new(input, 'UTF-8'); } catch (e2) {
                        txt = asciiOf(input);
                    }
                    console.log(TAG + ' [' + label + '] ' + jstr(mode) + ' in(' + input.length + ')=' + jstr(txt));
                } catch (e) { }
            };

            Cipher.doFinal.overload('[B').implementation = function (a) {
                dumpCipher('ENC' , this, a);
                var r = this.doFinal(a);
                try {
                    console.log(TAG + ' [ENC-OUT] b64=' + Java.use('android.util.Base64')
                        .encodeToString(r, 2) + ' hex=' + hexOf(r));
                } catch (e) { }
                return r;
            };
            Cipher.doFinal.overload('[B', 'int', 'int').implementation = function (a, o, l) {
                dumpCipher('CIPHER', this, a);
                var r = this.doFinal(a, o, l);
                try {
                    var s = Java.use('java.lang.String').$new(r, 'UTF-8');
                    console.log(TAG + ' [CIPHER-OUT] ' + jstr(s));
                } catch (e) {
                    console.log(TAG + ' [CIPHER-OUT] hex=' + hexOf(r));
                }
                return r;
            };
            console.log(TAG + ' OK  Cipher');
        } catch (e) { console.log(TAG + ' FAIL Cipher: ' + e); }

        /* ---------- 3. RSA 公钥 ---------- */
        try {
            var KF = Java.use('java.security.KeyFactory');
            KF.generatePublic.overload('java.security.spec.KeySpec').implementation = function (spec) {
                var r = this.generatePublic(spec);
                try {
                    var enc = r.getEncoded();
                    console.log(TAG + ' [RSA-PUB] alg=' + jstr(r.getAlgorithm()) +
                        ' b64=' + Java.use('android.util.Base64').encodeToString(enc, 0));
                } catch (e) { }
                return r;
            };
            console.log(TAG + ' OK  KeyFactory');
        } catch (e) { console.log(TAG + ' FAIL KeyFactory: ' + e); }

        /* ---------- 4. 目标类：密钥注入 ---------- */
        try {
            var Helper = Java.use('o00O.OooO00o');
            Helper.OooOOO.overload('java.lang.String', 'java.lang.String').implementation = function (a, b) {
                console.log(TAG + ' [SET-KEY] secretKey=' + jstr(a) + ' safeCode=' + jstr(b));
                return this.OooOOO(a, b);
            };
            Helper.OooOOO0.overload('java.lang.String').implementation = function (a) {
                console.log(TAG + ' [SET-PUBKEY] ' + jstr(a));
                return this.OooOOO0(a);
            };
            Helper.OooOO0.overload('java.lang.String').implementation = function (a) {
                console.log(TAG + ' [SECURE-REQ] plaintext=' + jstr(a));
                var r = this.OooOO0(a);
                return r;
            };
            Helper.OooO00o.overload('java.util.Map').implementation = function (m) {
                try { console.log(TAG + ' [SIGN-MAP] ' + jstr(m.toString())); } catch (e) { }
                var r = this.OooO00o(m);
                try { console.log(TAG + ' [SIGN-MAP-AFTER] ' + jstr(m.toString())); } catch (e) { }
                return r;
            };
            console.log(TAG + ' OK  o00O.OooO00o');
        } catch (e) { console.log(TAG + ' FAIL o00O.OooO00o: ' + e); }

        /* ---------- 5. OkHttp 请求与响应 ---------- */
        try {
            var RBuilder = Java.use('okhttp3.Request$Builder');
            RBuilder.build.implementation = function () {
                var req = this.build();
                try {
                    var u = req.url().toString();
                    if (u.indexOf('juzhi') >= 0 || u.indexOf('/api/') >= 0 || u.indexOf('proto') >= 0) {
                        console.log(TAG + ' [HTTP] ' + req.method() + ' ' + u);
                        var h = req.headers();
                        var n = h.size();
                        for (var i = 0; i < n; i++) {
                            console.log(TAG + '        hdr ' + h.name(i) + ': ' + h.value(i));
                        }
                        try {
                            var body = req.body();
                            if (body != null) {
                                console.log(TAG + '        body-type=' + body.contentType());
                            }
                        } catch (e) { }
                    }
                } catch (e) { }
                return req;
            };
            console.log(TAG + ' OK  OkHttp Request');
        } catch (e) { console.log(TAG + ' FAIL OkHttp: ' + e); }

        /* ---------- 6. 响应体解密后的 protobuf ---------- */
        try {
            var OooO = Java.use('o00OO0O0.o0ooOOo');
            var names = OooO.class.getDeclaredMethods();
            var hooked = 0;
            for (var i = 0; i < names.length; i++) {
                var mn = names[i].getName();
                if (mn.indexOf('OooOO') === 0) {
                    try {
                        (function (mname) {
                            var ovs = OooO[mname].overloads;
                            for (var j = 0; j < ovs.length; j++) {
                                var args = ovs[j].argumentTypes;
                                if (args.length === 1 && args[0].className === 'com.google.protobuf.ByteString') {
                                    ovs[j].implementation = function (bs) {
                                        try {
                                            var len = bs.size();
                                            var arr = bs.toByteArray();
                                            console.log(TAG + ' [PROTO] ' + mname + ' bytes(' + len + ') hex=' +
                                                hexOf(arr).substring(0, 300));
                                        } catch (e) { }
                                        return ovs[j].apply(this, arguments);
                                    };
                                    hooked++;
                                }
                            }
                        })(mn);
                    } catch (e) { }
                }
            }
            console.log(TAG + ' OK  proto parsers hooked=' + hooked);
        } catch (e) { console.log(TAG + ' FAIL proto parsers: ' + e); }

        console.log(TAG + ' ===== all hooks ready =====');
    });
}, 0);