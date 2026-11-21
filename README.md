# dsh-link-app

DSH Link 手机客户端（Flutter，协议 v2 + E2EE）。

- 协议契约：[docs/mobile-api-contract.md](docs/mobile-api-contract.md)
- 字节级实现笔记：[docs/PROTOCOL-NOTES.md](docs/PROTOCOL-NOTES.md)
- 连接策略（第一原则）：[docs/CONNECTIVITY.md](docs/CONNECTIVITY.md)
- 测试向量：`spec/e2ee-vectors.json`（与宿主同一份，改动只跟随上游）

## 构建

APK 由 GitHub Actions 出包（`.github/workflows/build.yml`），本机不需要 Flutter。
