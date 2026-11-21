"""给安卓壳装上「手机通知」通道（不引第三方插件，直接改 MainActivity）。

flutter create 生成的 MainActivity 是空的 `FlutterActivity` 子类，这里换成带
`MethodChannel('aidock/notify')` 的版本：
  - `ask`  → Android 13+ 申请 POST_NOTIFICATIONS 运行时权限
  - `show` → 用 NotificationChannel 发一条提醒（审批待处理、提问待回答、回合结束）

只依赖平台自带的 `android.app.Notification`，不碰 androidx.core，减少构建风险。
同时往 manifest 里补 POST_NOTIFICATIONS 声明。
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
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
                        show(title, body)
                        result.success(true)
                    }}
                    else -> result.notImplemented()
                }}
            }}
    }}

    private fun show(title: String, body: String) {{
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
        val n = builder
            .setSmallIcon(android.R.drawable.stat_notify_chat)
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
