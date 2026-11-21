"""Release APK 必需的四项：INTERNET 权限 + 相机权限 + 明文 HTTP 放行 + 桌面显示名。

flutter create 生成的 main manifest 既没有 INTERNET（它只写进 debug/profile），
也没有 usesCleartextTraffic，而 AIDock 直连的是 http://<ip>:<port>，
两者缺一都会让真机上所有请求直接失败。
"""
import pathlib
import sys

MANIFEST = pathlib.Path("android/app/src/main/AndroidManifest.xml")


def main() -> int:
    if not MANIFEST.exists():
        print("manifest not found", file=sys.stderr)
        return 1
    s = MANIFEST.read_text(encoding="utf-8")
    changed = []

    if "android.permission.INTERNET" not in s:
        s = s.replace(
            "<application",
            '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
            1,
        )
        changed.append("INTERNET")

    if "android.permission.CAMERA" not in s:
        s = s.replace(
            "<application",
            '<uses-permission android:name="android.permission.CAMERA"/>\n'
            '    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n'
            "    <application",
            1,
        )
        changed.append("CAMERA")

    if 'android:label="aidock"' in s:
        s = s.replace('android:label="aidock"', 'android:label="AIDock"', 1)
        changed.append("label")

    if "usesCleartextTraffic" not in s:
        s = s.replace(
            "<application",
            '<application\n        android:usesCleartextTraffic="true"',
            1,
        )
        changed.append("usesCleartextTraffic")

    MANIFEST.write_text(s, encoding="utf-8")
    print("patched:", ", ".join(changed) if changed else "already ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
