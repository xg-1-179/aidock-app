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
| 人工项 | 真机上点选与提交（io 无模拟器） |
