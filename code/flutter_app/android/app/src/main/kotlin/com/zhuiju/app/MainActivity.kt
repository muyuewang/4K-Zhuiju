package com.zhuiju.app

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 承接 Flutter 侧的「屏幕常亮」请求。
 *
 * 用 Window flag（FLAG_KEEP_SCREEN_ON）而不是 PowerManager.WakeLock：
 *   - WakeLock 需要 WAKE_LOCK 权限，且必须严格配对 acquire/release，
 *     漏一次就是持续耗电，异常路径很难兜住；
 *   - FLAG_KEEP_SCREEN_ON 绑定在窗口上，窗口不可见/销毁时由系统自动失效，
 *     不存在「忘了释放导致一直亮屏」的风险。
 *
 * 只在播放页打开、退出时关掉（见 lib/core/screen_awake.dart）。
 */
class MainActivity : FlutterActivity() {

    private val channelName = "com.zhuiju.app/screen"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAwake" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        setAwake(on)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun setAwake(on: Boolean) {
        runOnUiThread {
            if (on) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }
}