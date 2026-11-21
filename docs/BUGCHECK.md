# 交付前检查清单

每次出包前按这份清单过一遍，任何一条没过都不要发版。

## 一、协议正确性（自动化）

- [x] 官方 9 项 e2ee 向量全过（`packages/dsh_link_protocol/test/vectors_test.dart`）
- [x] 连接探测 7 项（先到先用 / 超时判负 / 全失败 / 路径记忆）
- [x] 客户端 MockHost 5 项（配对、列表解密、fresh 查询串、异常映射、SSE 帧）
- [x] 公网直连口用探针跑通：配对 → 列表（358 条）→ 新建会话 → 发消息 → 流式 70 帧（`~/.dsh/t_e2e.mjs`）
- [ ] 真机对真宿主：审批卡片点「允许一次/拒绝/以后都同意」（需人工，见第四节）

## 二、安卓打包（自动化 + 人工核对 manifest）

- [x] main manifest 含 `INTERNET` 权限
- [x] main manifest 含 `android:usesCleartextTraffic="true"`（直连是 http）
- [ ] minSdk / targetSdk 与真机系统对得上（安装包能在目标机型装上）
- [ ] 首次启动不崩（无空指针、无超时闪退）

## 三、界面（人工）

- [ ] 配对页：地址栏可填多个地址、连接码输满 6 位才可点连接、错误条可读
- [ ] 会话列表：状态点含义正确（蓝=运行中、黄=待审批、红=上轮失败、灰=空闲）
- [ ] 会话列表：下拉刷新、空态文案
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
7. 断开重连一次，确认不会残留旧流。

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
- [x] Release 名称、APK 文件名与 commit 对得上（`apk-33` / `AIDock-2ba968a.apk`）
