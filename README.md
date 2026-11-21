# AIDock 手机客户端

DeepSeek Harness 的手机伴侣：对着电脑上的会话发消息、看流式回复、批审批，
不依赖中转也能连（局域网直连 / 公网直连 / 中转都是候选，谁先答话用谁）。

- 插件端仓库：`xg-1-179/aidock`（基于 MIT 的 dsh-mobile-plugin 派生）
- 安卓安装包：见 Releases，tag 形如 `apk-18`

## 现在能做什么

| 能力 | 状态 |
|---|---|
| 六位连接码配对（不用扫码） | ✅ |
| 多地址并行探测（3 秒超时，先到先用，带诊断明细） | ✅ |
| 会话列表（运行中 / 待审批 / 上轮失败 / 置顶 状态点） | ✅ |
| 进入会话先回填最近 40 条历史（代码块单独成块渲染） | ✅ |
| 免码重连（凭据存手机本地，下次一键回去） | ✅ |
| 会话搜索（标题 / 最近一条消息 / 路径） | ✅ |
| 发消息 + SSE 流式回复 + 打断当前回合 | ✅ |
| 断线自动重连（退避 1→15 秒，回来补历史） | ✅ |
| 新建会话 | ✅ |
| 审批卡片（允许一次 / 拒绝 / 以后都同意） | ✅ |
| 语音输入、TTS、拍照分享直达 | ❌ 明确不做（手机自带输入法更好用） |
| iOS | ❌ 暂不出包 |

## 连接协议要点

协议是宿主既有的 v2 + E2EE（见 `docs/mobile-api-contract.md`），客户端只补了
文档没写、必须实测才知道的四条：

1. `canonical` 里的 QUERY **带前导 `?`**（宿主 `signedQuery` 原样拼）；
2. 响应信封是 `{v:2,n,c}` 两段，解密要拼回 `n‖c`；
3. 会话流是 **SSE** 不是 WebSocket，帧 AAD 还带 `seq`（从 1 起），`z=g` 表示 gzip；
4. 下行 AAD 用的是**请求**的 ts 与 nonce，不是响应里的 `n`。

另外两条客户端必须自己扛住的：

5. 列表响应（带 `revision` + `generatedAt`）是**双层信封**，正文在 `env` 里，解开才拿到 `items`；
6. 配对回包的授权（`token`、`deviceCredential`、`permissions`）**封在 `sealed` 里**，
   不解包就只能带着签名去撞 401。客户端在 `pair()` 里解出后自动附加到每个请求。

细节在 `docs/PROTOCOL-NOTES.md`。

## 连接策略（第一原则）

中转不是前提，只是候选之一。用户填几个地址就并行探测几个，
3 秒内谁先答话用谁，失败原因全部留在连接诊断里给用户看。
见 `docs/CONNECTIVITY.md`。

## 构建

本机不需要 Flutter/Android SDK，APK 全部在云端出：

- `.github/workflows/android.yml`：`flutter create` 现生 android 平台 →
  `scripts/patch_android_manifest.py` 补 INTERNET 权限与明文 HTTP →
  构建 release → 发到 Release。
- `.github/workflows/protocol-ci.yml`：协议包的向量/连接/客户端测试。

> 真机必须那两个 manifest 项：`flutter create` 生成的 main manifest
> 既没有 INTERNET，也没放开明文 HTTP，缺任何一项所有 http 请求都会直接失败。

## 目录

```
app/                        Flutter 应用（页面、状态、主题）
packages/dsh_link_protocol/ 协议实现：加密、信封、连接探测、客户端
docs/                       契约、字节级笔记、连接策略
scripts/                    CI 用的构建前补丁
```

## 测试

`dart test` 覆盖：9 项官方 e2ee 向量、7 项连接探测、5 项客户端 MockHost 集成。
