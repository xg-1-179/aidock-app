# 交付前检查清单

每次出包前按这份清单过一遍，任何一条没过都不要发版。

## 一、协议正确性（自动化）

- [x] 官方 9 项 e2ee 向量全过（`packages/dsh_link_protocol/test/vectors_test.dart`）
- [x] 连接探测 7 项（先到先用 / 超时判负 / 全失败 / 路径记忆）
- [x] 客户端 MockHost 6 项（配对、列表解密、fresh 查询串、异常映射、SSE 帧、配对后每请求带 Bearer）
- [x] 公网直连口用探针跑通：配对 → 列表（358 条）→ 新建会话 → 发消息 → 流式 70 帧（`~/.dsh/t_e2e.mjs`）
- [x] 授权链路：配对回包的 `sealed` 解出 `token`/`deviceCredential`，后续每请求带
      `Authorization: Bearer` + `X-Dsh-Device-Credential`（`test('配对后每个请求都带上 paired 的授权头')`）
- [x] 凭据有效期实测 `credentialExpiresAt` = 现在 + 8760 小时（一年），权限十项全给
      （`view/files.read/input/dispatch/approve/operate/files.write/transfer/manage/config`）
- [x] 凭据过期不再无限重连：流上出现 401/403 直接停表并提示「断开后用六位码重新连一次」
- [ ] 真机对真宿主：审批卡片点「允许一次/拒绝/以后都同意」（需人工，见第四节）

## 二、安卓打包（自动化 + 人工核对 manifest）

- [x] main manifest 含 `INTERNET` 权限
- [x] main manifest 含 `android:usesCleartextTraffic="true"`（直连是 http）
- [ ] minSdk / targetSdk 与真机系统对得上（安装包能在目标机型装上）
- [ ] 首次启动不崩（无空指针、无超时闪退）
      —— 已知风险：`shared_preferences` 在部分国产 ROM 上首次读写慢，读取失败会被 try/catch 吞掉，不影响填码连接

## 三、界面（人工）

- [ ] 配对页：地址栏可填多个地址、连接码输满 6 位才可点连接、错误条可读
- [ ] 会话列表：状态点含义正确（蓝=运行中、黄=待审批、红=上轮失败、灰=空闲）
- [x] 会话列表：下拉刷新、搜索框（标题/第二行）、空态文案区分「没有会话」与「没有匹配」
- [x] 聊天页：流式增量自动贴底，用户上翻时不抢滚动位置
- [ ] 聊天页：用户/助手气泡区分、流式增量不重复、可打断
- [ ] 审批卡：三颗按钮文案清楚，点完卡片消失
- [ ] 深色主题下对比度足够（正文 ≥ 4.5:1）
- [ ] 长文本/长标题不溢出，窄屏（360dp）不挤

## 四、端到端（人工，每次协议或插件改动都要重做）

1. 电脑端打开 `/api/mobile/v1/link/panel` 拿六位码；
2. 手机填地址 + 码 → 连接；
3. 会话列表出来（不再 500 apiProxy）；
4. 进一个会话，看历史是否回填；
5. 发一句「你好」，看是否流式回、结束后不再重复；
6. 触发一次需要审批的工具，看卡片是否弹出、点允许后是否继续跑；
7. 断开重连一次，确认不会残留旧流；
8. 杀掉 App 重开，配对页应出现「上次连接的电脑」，点一下就回去（免码）；凭据过期时提示重新拿码。

## 五、插件侧（自动化 + 人工）

- [x] `node --check`：`lib/routes/mobile-api.js`、`lib/routes/aidock-panel.js`、
      `lib/relay/lan-proxy.js`、`lib/impl.js`
- [x] 面板渲染冒烟：`panelPayload()` 字段齐全、`renderPanel()` 含码与地址
- [x] 41873 公网端口：`/link/info`、`/health` 免鉴权放行（200）；`/link/panel` 收紧为仅本机
- [x] `/link/code`、`/link/panel` 仅本机：转发层直接 403 `local-only`，宿主侧见到 `x-aidock-edge` 也判非本机
- [x] 连接码 10 分钟轮换（`~/.dsh/aidock-code.json`）、面板每 20 秒续期
- [x] `/api/mobile/v1/sessions` 与 `/link/sessions` 均 200（apiProxy 兼容桥已生效）

## 六、仓库卫生（自动化）

- [x] 推送后的树里没有反斜杠路径（`pushproto.mjs` 已跳过含 `\` 的路径，并用 `PRUNE` 清过历史）
- [x] 没有把 token/密钥写进仓库（工作区 grep `gho_` 无命中，token 只在 `~/.dsh/github-token.txt`）
- [x] Release 名称、APK 文件名与 commit 对得上（`apk-39` / `AIDock-217ac28.apk`）

## 七、2026-11-22 全量代码审查修掉的四条

- [x] **自己发的话不会出现两条**：本地乐观插入一条 user 消息后，宿主 SSE 还会回推
      `user/message`；`_onFrame` 现在拿「末尾是否已有同文本 user 消息」判重。
- [x] **中断重连不再吞消息**：`_catchUp` 改按主机 `id` 去重（`_seenIds`），老宿主没有 id
      时只对齐末尾两条；原先用「全表 role+text」判断，用户连发两条相同文本时第二条会消失。
- [x] **流式收尾不重复正文**：`assistant/message` 只在「还在流式 / 文本相同 / 是流式文本的
      全量版本」时归到同一个气泡，否则才新起一条。
- [x] **重连横幅不赖着不走**：挂上流就先收掉「正在自动重连…」，不必等 15 秒后的心跳帧。

## 八、提问卡（ask_user_question）端到端

| 项 | 结论 |
| --- | --- |
| 插件别名 | `/api/mobile/v1/link/question/respond` → `questions.handleQuestionRespond`，权限表映射 `V.APPROVE` |
| 帧契约 | `question/requested`（`rpcId` 在帧级、`questions[]` 在 payload）、`question/resolved`（`questionRpcId`） |
| 回答体 | `{rpcId, sessionId, answer:{answers:[{id, selected:[label...], custom?}]}}`，每题恰好一条，否则 400；无挂起项回 409 |
| 探针实测 | 新建会话 → 让 agent 调 `ask_user_question` → 收到 `question/requested`（题 `color`，选项「红色/蓝色」）→ `POST /link/question/respond` **200 accepted** → 帧流出现 `question/resolved` → `turn/end`，整轮跑完 |
| 客户端 | `DshClient.respondQuestion`、`AppState.answerQuestion`、`_onFrame` 两分支（upsert / 移除）、`_QuestionDock` 单选/多选/自由输入 |
| 附件接口 | `POST /api/mobile/v1/link/session/attachment`（`{sessionId, attachmentId}` → `{ok, mediaType, data:<base64>, name}`；实测 200 / `image/png` / 124 字节 base64） |
| 人工项 | 真机上点选与提交（io 无模拟器） |

## 九、二维码连接

| 项 | 结论 |
| --- | --- |
| 插件 | `GET /api/mobile/v1/link/qr.svg?w=320` 用 `qrcode@1.5.4` 渲染，内容 `aidock://v1?h=<地址>&c=<六位码>&i=<实例>` |
| 面板 | `renderPanel` 内嵌 `<img src="…/qr.svg?w=352">`，码轮换时按 `lastCode` 变化重取（带 `t=` 破缓存） |
| App | `ScanPage`（`mobile_scanner ^5.2.3`）只认 `aidock://` 前缀，扫到后回填地址与六位码并直接连接；其它二维码提示「这不是 AIDock 的连接码」 |
| 权限 | `patch_android_manifest.py` 增加 `CAMERA` 与 `android.hardware.camera required=false` |
| 安全 | 公网口 `/link/qr.svg`、`/link/panel`、`/link/code` 均 403（转发器 `LOCAL_ONLY` + 插件 `x-aidock-edge` 双层），`X-Aidock-Code` 头保留 |
| 实测 | 本机 qr.svg 200（2,423 字节 SVG）；公网三条路由 403、`/health` 200；payload 经 URL 解析回填 `h=http://101.43.213.201:41873`、`c=859603` |
| 人工项 | 真机相机扫码（io 无摄像头） |

## 十、图片消息

| 项 | 结论 |
| --- | --- |
| 发送 | 聊天输入框左侧「发图片」→ 相册选图（`image_picker`，压到 1600px / 质量 78）→ `content` 块 `[{text?}, {type:'image', data:<base64>, mediaType, name}]` |
| 协议 | `DshClient.sendContent(sessionId, content)` → `POST /api/mobile/v1/link/session/send`（宿主 `handleSend` 认 `content` 或 `text`） |
| 宿主限制 | 明文 8MB / 线上 10.7MB；图片块带 `data` 就直接内联，不必走 uploadId |
| 实测（公网 41873） | `SEND 200 {"ok":true,"accepted":true}`；随后 `/link/messages` 出现 `role:user` 且 `blocks=text|image`，模型答「红色」→ 图确实进了模型 |
| 失败形状 | 图片数据不可解码时宿主回 `400 {"code":"session/attachment-invalid","reason":"INVALID_IMAGE"}`（我第一次用坏 base64 试出来的） |
| 显示 | 历史里带图无正文的轮次显示「（图片）」/「（N 张图片）」；气泡内按 `attachmentId` 现取字节渲染缩略图（一屏最多补 8 张，取不到就退回文字占位） |
| 人工项 | 真机相册选图（有系统的权限弹窗）、超大图（>8MB 原图）会被压缩后再发 |

## 十一、会话管理与工作区

| 项 | 结论 |
| --- | --- |
| 重命名 | 会话条目长按 → 「重命名会话」→ `POST /link/session/rename {sessionId, title}`；实测 `200 {"ok":true,"title":"图片颜色识别","seq":23}` |
| 复制 ID | 长按 → 「复制会话 ID」（调试、报障时用） |
| 工作区 | `GET /link/workspaces`（列表类双层 `env`，客户端已自动解）；实测 `200`，本机 1 个工作区 |
| 新建会话选工作区 | 长按 FAB → 工作区列表；只有一个工作区时直接建，不弹窗 |
| 容错 | `newSession` 不传 workspaceId 时用宿主默认工作区；传了不存在的 id 宿主回 400，错误直接显示在错误带 |
| 人工项 | 真机长按手势（会话条目、FAB）、重命名后列表就地更新 |

## 十二、多机管理

| 项 | 结论 |
| --- | --- |
| 存储 | `SharedPreferences` 键 `aidock.machines`，JSON 数组，每台存 `host/key/keyId/instanceId/token/credential/permissions/lastAt` |
| 迁移 | 老版本只存一台（散键 `aidock.host` 等），启动时自动并进列表并清掉旧键 |
| 列表 | 配对页「连过的电脑」逐台列出地址 + 上次连接时间，各自「连接这台」/「忘掉」 |
| 去重 | 同一个 `host` 再配对一次只更新那一条，不会堆两行 |
| 忘掉 | 只删手机本地记录，电脑上的设备授权仍在（要真正吊销得在电脑面板操作） |
| 人工项 | 连两台不同电脑后互相切换；忘掉其中一台后另一台仍能直连 |

## 十三、命令面板

| 项 | 结论 |
| --- | --- |
| 数据源 | `GET /link/commands?sessionId=…`，每条 `{name, description, input:{hint}}`；实测 13 条 |
| 触发 | 输入框以 `/` 开头且还没打空格时，底部弹出候选；再打字按前缀过滤，最多 6 条 |
| 选中 | 点一下把 `/name ` 填进输入框，光标落在末尾，接着打参数 |
| 发送 | 走普通 `session/send`；宿主见到「单个 text 块且以 / 开头」会当 Slash 命令派发（回包 `handledAs:'command'`） |
| 容错 | 命令表取不到就不弹（不影响正常发消息） |
| 人工项 | 真机打 `/` 弹层、点选后光标位置、中文输入法下不出错 |

## 十四、手机通知（审批 / 提问 / 回合结束）

| 项 | 结论 |
| --- | --- |
| 做法 | 不引第三方通知插件，直接改生成的 `MainActivity`：`scripts/patch_android_notify.py` 写入 `MethodChannel('aidock/notify')`，只在 `configureFlutterEngine` 里注册 |
| 权限 | manifest 加 `POST_NOTIFICATIONS`；Android 13+ 启动时 `Notifier.ask()` 弹一次系统授权，拒了不影响其它功能 |
| 触发条件 | 只有 App 退到后台（`appForeground == false`）才发：① 新的审批卡（去重后首次入列）② 新的提问卡 ③ `turn/end` 且这一轮是手机发起的 |
| 文案 | 审批「需要你批准：<工具名>」+ fact；提问「电脑在等你回答」+ 第一句问题；回合结束「这一轮跑完了」+ 最后一条回复前 80 字 |
| 实现 | `app/lib/notify.dart` 的 `Notifier.ask()/show()`，全 try/catch（桌面或测试环境没有通道时静默）；`app/lib/main.dart` 用 `WidgetsBindingObserver` 维护 `appForeground` |
| 构建验证 | CI 里 `patch_android_notify.py` 覆写 MainActivity 后 `flutter build apk --release` 通过即代表 Kotlin 可用（`android.app.Notification` 平台自带，不依赖 androidx.core） |
| 人工项 | 真机锁屏/后台时是否弹出、点通知是否能回到 App、Android 13 首次授权框 |

## 十五、深链接（扫面板二维码直接进 App）

| 项 | 结论 |
| --- | --- |
| 链路 | 面板二维码内容 `aidock://v1?h=<地址>&c=<六位码>&i=<instanceId>` → 系统相机/扫码器 → Android intent → `MainActivity.onNewIntent` 或冷启动 `intent.data` → `MethodChannel('aidock/link')` → Dart |
| 安卓侧 | `scripts/patch_android_notify.py` 同时注入 `aidock/link` 通道（`initial` 取冷启动、`link` 推热启动）与 manifest 的 `<intent-filter>`（`scheme="aidock"`、`BROWSABLE`） |
| Dart 侧 | `app/lib/deeplink.dart`（`DeepLink.initial()` / `DeepLink.listen()`）+ 配对页 `_fromDeepLink()`：解析出地址与码后自动填好并直接连 |
| 与 App 内扫码的关系 | App 内「扫面板二维码」走 `mobile_scanner`（需相机权限）；系统相机扫码走 intent（不需要 App 内相机）。两条路互不冲突 |
| 人工项 | 用手机系统相机扫面板二维码 → 是否弹出「用 AIDock 打开」→ 打开后是否自动连上 |

## 十六、安全边界与安装验证

| 项 | 结论 |
| --- | --- |
| 六位码防爆破 | 插件 `lib/routes/mobile-api.js` 的 `aidockPairGuard`：同一来源 10 分钟内「码不对」满 8 次回 `429`（带 `retry-after`），全机累计失败 20 次删掉 `~/.dsh/aidock-code.json` 让码作废重生成；码对了调 `success()` 清计数，所以手快输错几次不耽误事 |
| 只数「码不对」 | 码对但封包坏（版本不匹配等）返回 401 但**不计数**，避免正常用户被锁。实测：7 次错码 → 输对 → 再 7 次错码，全程 401 无 429 |
| 来源识别 | 转发层盖 `x-aidock-edge: 1` 与 `x-aidock-client: <真实对端 IP>`（宿主看到的源地址恒为 `127.0.0.1`）；客户端自带的同名头被丢弃，`x-aidock-code` 保留。换 nginx/frp 时必须补这两枚，否则所有公网请求算同一来源 |
| 本机专属页 | `/api/mobile/v1/link/code`、`/link/panel`、`/link/qr.svg` 在公网口一律 403（`local-only`），本机 200。带六位码的页面不能从公网读到 |
| 安装名一致性 | `cordis.patch.yml` 的 `insert: [{ id: dsh-mobile, name: 'aidock' }]` 必须与 `package.json` 的 `name` 一致，否则 Loader 解析不到入口、整棵插件树加载失败；`host.js` 的 `BIN_NAME` 已改为从 `package.json` 读 |
| 安装实测 | 打 `npm pack` 出的 `aidock-0.1.0.tgz`（294 文件 / 1.8MB）装进全新 profile：`dsh plugin --profile aidocktest add "file:<tgz>"` → `+ aidock 0.1.0`，`bundles: ['@deepseek-ai/dsh-base', 'aidock']`，`node_modules/aidock/lib/index.js` 与改好的 `cordis.patch.yml` 都在位（验证完已删除该临时 profile） |
| 端到端复验 | 公网口 `t_full.mjs`：`PAIR 200 / SESSIONS 369 / MESSAGES / MODELS / SELECT / PRESETS` 全绿；`/link/info` 200、`/link/code` 403 |

## 十七、自检脚本（本轮新增，已实测全绿）

电脑侧插件仓库带了 `tools/selftest.js`：不装任何依赖，按 App 的真实顺序把整条链路跑一遍，
适合「改完插件先自证没改坏」。

| 项 | 结果 |
|---|---|
| 本机 `node tools/selftest.js` | **12 passed / 0 failed**（探活、面板、六位码、配对、授权解封、会话列表 370、历史、模型） |
| 本机加 `--send --stream` | 同上 + 新建会话 200、发送 200、SSE `text/event-stream` 200 |
| 公网口 `--base http://101.43.213.201:41873 --send --stream` | **14 passed / 0 failed**（另含 `/link/panel`、`/link/code`、`/link/qr.svg` 三个 403） |
| 退出码 | 0 = 全过；1 = 有 FAIL，便于接 CI |

口径提醒：**实例号以 `/link/info` 为准**。`/api/mobile/v1/health` 是插件早期一代注册的路由，
`POST /api/relay/reload-implementation` 不会重新注册已存在的路由，它闭包里的 `state` 停在重启
前那一代，`instanceId` 可能仍是旧值（自检会打印一行提示）。用旧实例号派生 `pairKey` 会让配对
恒 401 —— 这一步踩过，已把 `/health` 的实例号改为从 `relay.json` 现读（重启宿主后生效）。
