package com.zhuiju.app

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.wifi.WifiManager
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 承接三个 Flutter 侧请求：
 *
 *   1. 屏幕常亮（com.zhuiju.app/screen）
 *      用 Window flag（FLAG_KEEP_SCREEN_ON）而不是 PowerManager.WakeLock：
 *        - WakeLock 需要 WAKE_LOCK 权限，且必须严格配对 acquire/release，
 *          漏一次就是持续耗电，异常路径很难兜住；
 *        - FLAG_KEEP_SCREEN_ON 绑定在窗口上，窗口不可见/销毁时由系统自动失效，
 *          不存在「忘了释放导致一直亮屏」的风险。
 *      只在播放页打开、退出时关掉（见 lib/core/screen_awake.dart）。
 *
 *   2. 是否电视设备（com.zhuiju.app/tv）
 *      Flutter 侧没法判断「用户手里是不是遥控器」，只能问系统。
 *
 *   3. DLNA 多播锁（同 com.zhuiju.app/tv 通道，方法名 acquire/releaseMulticast）
 *      Wi-Fi 芯片默认会丢弃目的地址不是本机的多播包，SSDP 用的正是
 *      239.255.255.250 这个多播地址。不持有 MulticastLock 时，
 *      发送 M-SEARCH 一切正常但永远收不到任何回应——表现为
 *      「搜不到设备」，而同一网络下的其它投屏 App 全都正常，
 *      极其容易被误判成协议实现有问题。
 */
class MainActivity : FlutterActivity() {

    private val screenChannel = "com.zhuiju.app/screen"
    private val tvChannel = "com.zhuiju.app/tv"

    /** SSDP 搜索期间持有的多播锁，配对释放 */
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, screenChannel)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, tvChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTv" -> result.success(isTvDevice())
                    "acquireMulticast" -> {
                        acquireMulticast()
                        result.success(true)
                    }
                    "releaseMulticast" -> {
                        releaseMulticast()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 拿多播锁。必须 setReferenceCounted(false)：
     * 默认是引用计数的，acquire 两次就要 release 两次，
     * 而 Dart 侧是按「开始搜索/结束搜索」成对调用的，
     * 中途异常退出很容易多 acquire 一次，泄漏的锁会让 Wi-Fi
     * 一直保持高功耗唤醒。
     */
    private fun acquireMulticast() {
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = applicationContext
                .getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
            val lock = wifi.createMulticastLock("zhuiju_dlna").apply {
                setReferenceCounted(false)
            }
            lock.acquire()
            multicastLock = lock
        } catch (e: Exception) {
            // 没拿到锁不致命：部分设备（尤其是有线连接）本来就不需要它
            android.util.Log.w("ZhuijuTv", "acquireMulticast failed: $e")
        }
    }

    private fun releaseMulticast() {
        try {
            val lock = multicastLock
            if (lock != null && lock.isHeld) lock.release()
        } catch (e: Exception) {
            android.util.Log.w("ZhuijuTv", "releaseMulticast failed: $e")
        } finally {
            multicastLock = null
        }
    }

    override fun onDestroy() {
        // 页面被系统回收时兜底释放，避免锁泄漏
        releaseMulticast()
        super.onDestroy()
    }

    /**
     * 三重判定，任意一条命中即认为是电视：
     *
     *   1. UiModeManager 当前模式是 TELEVISION —— Android TV / Google TV 的标准上报；
     *   2. 声明了 leanback feature —— 老盒子和部分魔改固件只声明这个；
     *   3. 声明了 television feature —— 同上，另一套命名。
     *
     * 只看 1 会漏判（部分盒子把 UI_MODE 报成 NORMAL），只看 2/3 也会漏
     * （有的固件压根不声明 feature）。三条并起来覆盖率最高。
     *
     * 注意：这里只回答「它是不是电视」，不管用户是否手动覆盖，
     * 覆盖逻辑在 Dart 侧（lib/core/tv.dart），原生保持纯粹的事实判断。
     */
    private fun isTvDevice(): Boolean {
        val uiMode = getSystemService(UI_MODE_SERVICE) as? UiModeManager
        val mode = uiMode?.currentModeType
        if (mode == Configuration.UI_MODE_TYPE_TELEVISION) return true

        val pm = packageManager
        if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) return true
        if (pm.hasSystemFeature(PackageManager.FEATURE_TELEVISION)) return true

        return false
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