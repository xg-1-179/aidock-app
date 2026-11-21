"""给安卓壳装上「手机通知 + 深链接」两条通道（不引第三方插件，直接改 MainActivity）。

flutter create 生成的 MainActivity 是空的 `FlutterActivity` 子类，这里换成带
`MethodChannel('aidock/notify')` 的版本：
  - `ask`  → Android 13+ 申请 POST_NOTIFICATIONS 运行时权限
  - `show` → 用 NotificationChannel 发一条提醒（审批待处理、提问待回答、回合结束）

另外接 `MethodChannel('aidock/link')`：把系统相机/扫码器打开 `aidock://v1?...`
时带进来的 URL 交给 Dart（`initial` 取冷启动那一条，`link` 事件推热启动）。
只依赖平台自带 API，不碰 androidx.core，减少构建风险。
同时往 manifest 里补 POST_NOTIFICATIONS 声明与 `aidock://` 的 intent-filter。
"""
import pathlib
import sys

NOTIFY_KT = '''package {package}

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {{
    private val channelId = "aidock.alerts"
    private val channelName = "AIDock 提醒"
    private var linkChannel: MethodChannel? = null
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        linkChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aidock/link")
        linkChannel!!.setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "initial" -> {{
                    val url = pendingLink ?: aidockLink(intent)
                    pendingLink = null
                    result.success(url)
                }}
                else -> result.notImplemented()
            }}
        }}
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aidock/notify")
            .setMethodCallHandler {{ call, result ->
                when (call.method) {{
                    "ask" -> {{
                        if (Build.VERSION.SDK_INT >= 33) {{
                            requestPermissions(
                                arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001
                            )
                        }}
                        result.success(true)
                    }}
                    "show" -> {{
                        val title = call.argument<String>("title") ?: "AIDock"
                        val body = call.argument<String>("body") ?: ""
                        val sessionId = call.argument<String>("sessionId") ?: ""
                        show(title, body, sessionId)
                        result.success(true)
                    }}
                    else -> result.notImplemented()
                }}
            }}
    }}

    override fun onNewIntent(intent: android.content.Intent) {{
        super.onNewIntent(intent)
        setIntent(intent)
        val url = aidockLink(intent) ?: return
        val ch = linkChannel
        if (ch == null) {{
            pendingLink = url
        }} else {{
            ch.invokeMethod("link", url)
        }}
    }}

    private fun aidockLink(intent: android.content.Intent?): String? {{
        val data = intent?.data ?: return null
        if (data.scheme != "aidock") return null
        return data.toString()
    }}

    private fun show(title: String, body: String, sessionId: String) {{
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder: Notification.Builder = if (Build.VERSION.SDK_INT >= 26) {{
            nm.createNotificationChannel(
                NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_HIGH)
            )
            Notification.Builder(this, channelId)
        }} else {{
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }}
        // 点通知回到 App：带会话 id 时用 `aidock://open?session=<id>`，由 Dart 侧
        // `DeepLink.sessionOf` 认出来并直接打开那条会话；没有会话 id 就只是打开 App。
        val openUrl = if (sessionId.isNotEmpty)
            "aidock://open?session=" + android.net.Uri.encode(sessionId)
        else "aidock://open"
        val openIntent = android.content.Intent(this, MainActivity::class.java).apply {{
            action = android.content.Intent.ACTION_VIEW
            data = android.net.Uri.parse(openUrl)
            flags = android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP or
                android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP
        }}
        val flags = if (Build.VERSION.SDK_INT >= 23)
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        else android.app.PendingIntent.FLAG_UPDATE_CURRENT
        val pi = android.app.PendingIntent.getActivity(this, 7, openIntent, flags)
        val n = builder
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentIntent(pi)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .build()
        nm.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), n)
    }}
}}
'''


def main() -> int:
    root = pathlib.Path("android/app/src/main/kotlin")
    hits = list(root.rglob("MainActivity.kt"))
    if not hits:
        print("MainActivity.kt not found", file=sys.stderr)
        return 1
    path = hits[0]
    text = path.read_text(encoding="utf-8")
    package = "com.aidock.aidock"
    for line in text.splitlines():
        if line.startswith("package "):
            package = line.split("package ", 1)[1].strip()
            break
    path.write_text(NOTIFY_KT.format(package=package), encoding="utf-8")
    print(f"notify bridge: {path} (package {package})")

    manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
    s = manifest.read_text(encoding="utf-8")
    if "android.permission.POST_NOTIFICATIONS" not in s:
        s = s.replace(
            "<application",
            '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\n    <application',
            1,
        )
        manifest.write_text(s, encoding="utf-8")
        print("notify permission: POST_NOTIFICATIONS")

    m = manifest.read_text(encoding="utf-8")
    if 'android:scheme="aidock"' not in m:
        filter_block = (
            '            <intent-filter>\n'
            '                <action android:name="android.intent.action.VIEW" />\n'
            '                <category android:name="android.intent.category.DEFAULT" />\n'
            '                <category android:name="android.intent.category.BROWSABLE" />\n'
            '                <data android:scheme="aidock" />\n'
            '            </intent-filter>\n'
            '        </activity>'
        )
        idx = m.find('        </activity>')
        if idx != -1:
            m = m[:idx] + filter_block + m[idx + len('        </activity>'):]
            manifest.write_text(m, encoding="utf-8")
            print("link intent-filter: aidock://")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
