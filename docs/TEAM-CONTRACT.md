# 团队协作契约（AIDock App 一次性大批量开发）

仓库根：`C:\Users\Administrator\Desktop\文件夹三\dsh-link-app`（远端 `xg-1-179/aidock-app`）。

## 红线（违反就会互相覆盖）

以下文件**只有主控能改**，任何人不得编辑：
`app/lib/app_state.dart`、`app/lib/pages/chat_page.dart`、`app/lib/pages/sessions_page.dart`、
`app/lib/pages/more_page.dart`、`app/lib/pages/pair_page.dart`、`app/lib/main.dart`、
`app/lib/theme.dart`、`app/pubspec.yaml`、`app/lib/notify.dart`、`app/lib/deeplink.dart`、
`app/lib/keepalive.dart`、`packages/**`、`scripts/**`、`.github/**`、`docs/**`、`README.md`。

你**只能新建自己名下的文件**（下面各任务里写明）。需要主控接线的地方，在完成说明里说清「哪个页面、怎么接」。

## 数据访问

```dart
import 'package:dsh_link_protocol/dsh_link_protocol.dart';

// client.api 会自动补 /api/mobile/v1 前缀并带上授权头
final Map<String, dynamic> r = await client.api('GET', '/plugins');
final Map<String, dynamic> r2 = await client.api('POST', '/plugin/market/install',
    payload: {'spec': 'dsh-mobile-plugin@0.5.88'});
```

- `api(method, path, {String query = '', Map<String, dynamic>? payload})`
- `query` 必须自带前导 `?`（例如 `'?name=xxx'`）；需要用 `Uri.encodeQueryComponent`。
- 列表类响应可能是双层信封：外层 `{ok, revision, generatedAt, env}`，`api()` 已经解好，直接读 `items` / `bundles` / `records` 等字段。
- 失败抛 `DshClientException`（有 `.status`、`.message`）；401/403 表示凭据过期，提示用户重新配对，不要无限重试。

## 宿主契约从哪里查

插件源码在本机：`~/.dsh/profiles/web/node_modules/dsh-mobile-plugin/lib/mobile/*.js`
（`plugins.js`、`plugin-market.js`、`schedule.js`、`session-search.js`、`monitor.js`
`file-*.js`、`session-send.js`、`session-artifacts.js` …）。
**以源码为准**：参数名、响应字段、错误码都要看一眼再写，不要凭空猜。

## 代码风格

- Flutter **3.24.5**：没有 `Color.withValues`（用 `withOpacity`），没有 `WidgetStateProperty`（用 `MaterialStateProperty`）。
- 颜色只用 `AidockColors`（`app/lib/theme.dart`）：`bg / surface / surfaceAlt / line / text / textDim / accent / accentSoft / ok / warn / danger`。
- 深色 Material 3；圆角 12–16；分隔用 `AidockColors.line`；不要引入新的 UI 库。
- 状态用 `ChangeNotifier` 控制器模式（参考 `app/lib/app_state.dart` 的写法），页面用 `ListenableBuilder`/`AnimatedBuilder` 订阅。
- 不要 `print`；不要留 TODO 注释；不要 unused import（CI 会跑 `flutter analyze`，warnings 不阻塞但错误会）。
- 新增依赖**不要改 pubspec**：需要什么写进完成说明，主控统一加。

## 交付说明（必须写）

1. 新建了哪些文件（完整相对路径）。
2. 入口 widget 的构造函数签名（主控照着接线）。
3. 需要主控在哪些文件加什么（一行一句）。
4. 你用到的宿主端点 + 响应字段（从源码核对过的那种）。
