# 协议 v2 字节级实现笔记（已用官方 test/e2ee-vectors.json 全量验证通过）

> 验证脚本：`~/.dsh/verify2.mjs`、`~/.dsh/v3.mjs`、`~/.dsh/v4.mjs`。9 项向量全部 PASS。
> 结论：按下列规则实现，即可与 dsh-mobile-plugin 宿主（0.5.88/0.5.90）互通。

## 1. 密钥派生（HKDF-SHA256，输出 32B）

| 名称 | ikm | salt | info |
|---|---|---|---|
| `pairKey` | 票据 ticket 的**原始 32 字节**（二维码里是 base64url，先解码） | `instanceId` 的 UTF-8 字节 | `dsh-pair-v2` |
| `keyUp` | `deviceKey` 32 字节（base64url 解码后） | **空**（0 长度，不是空字符串以外的任何东西） | `dsh-v2|up` |
| `keyDown` | 同上 | 空 | `dsh-v2|down` |
| `keySig` | 同上 | 空 | `dsh-v2|sig` |

## 2. AEAD：AES-256-GCM，tag 16 字节，nonce 12 字节

封包字节形状：`nonce(12) || ciphertext || tag(16)`，整体做**标准 base64** 放进 `sealed` / `c`。

各场景 AAD（UTF-8）：

| 场景 | AAD |
|---|---|
| 配对请求 / 回包 | `pair|v2|<instanceId>` |
| 请求明文 | `v2|up|<METHOD>|<PATH>`（PATH 从 `/api/mobile/v1/` 起算，含该前缀，METHOD 大写） |
| 私密查询参数 | `v2|params|<requestTs>|<nonce_b64url>` |
| 下行响应 | `v2|down|<METHOD>|<PATH>|<requestTs>|<请求的 nonce_b64url>` |

## 3. 签名（避免重放）

请求体信封 JSON：`{"v":2,"c":"<base64(sealed)>"}`（**紧凑无空格**）。

```
bodyHash  = hex(sha256( UTF8( JSON.stringify({v:2,c:<c>}) ) ))   // 注意：哈希的是信封 JSON 文本，不是密文字节
canonical = ["v2", METHOD, PATH, QUERY, String(ts), nonce_b64url, bodyHash].join("\n")
X-Dsh-Sig = base64url( HMAC-SHA256(keySig, UTF8(canonical)) )      // 32 字节 → 43 字符
```

请求头：`X-Dsh-Key-Id`、`X-Dsh-Ts`（毫秒）、`X-Dsh-Nonce`（base64url）、`X-Dsh-Sig`、可选 `X-Dsh-Params`、`X-Dsh-Proto: 2`。

## 4. 配对请求

```
POST /api/mobile/v1/pair            （宿主应答；局域网直连同义入口 /__lan_pair）
{ "instanceId": "<可选，带了就必须匹配>", "sealed": "<base64>", "ticketId": "<可选>" }
```

`sealed` 明文 JSON：`{ "deviceKey": "<43 字符 base64url>", "keyId": "<16 位小写 hex>", "device": { "name": "...", "platform": "..." } }`。

回包：`{ "ok": true, "proto": 2, "sealed": "<base64>" }`，用 `pairKey` + `pair|v2|<instanceId>` 解封。
配对成功后该二维码作废（一次性）。

## 5. 已知协议分层

- v1：六位配对码、明文，仅为兼容旧客户端保留，新客户端不实现。
- v2：扫码带 ticket、E2EE 信封。**协议版本在配对时定死**，之后不协商。
- 被动降级检测：凭据带 `deviceKey` 但请求没带 `X-Dsh-Proto: 2` → 宿主回 `400 e2ee-required`。

## 6. 注意的坑

- 官方向量里 `*Sealed` 字段是 **hex**，不是 base64（我第一次按 base64 比对全 FAIL）。
- `salt` 为"空"时是**零长度 buffer**，不是 UTF-8 空串以外的填充。
- canonical 的请求路径与 query 分开两行；query 含前导 `?`，没有 query 时为空串（需再核对宿主代码）。
- 时戳允许 ±5 分钟偏差。
