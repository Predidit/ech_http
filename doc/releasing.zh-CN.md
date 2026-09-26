# 测试、维护与版本发布指南

[English](releasing.md) | [简体中文](releasing.zh-CN.md)

本指南详细记录了 `ech_http` 项目的本地测试检查、公网 Live 端到端验证、预编译原生 SDK 升级流程、Mozilla CA 根证书维护及正式发布至 [pub.dev](https://pub.dev) 的操作规范。

---

## 1. 本地代码质量与静态检查

在提交代码或发布前，必须在具备对应原生构建工具链的环境中依次运行以下检查命令：

```sh
# 1. 下载依赖
dart pub get

# 2. 检查全工程代码格式化（不符合将返回非零退出码）
dart format --output=none --set-exit-if-changed lib hook test example tool

# 3. 严格静态语法分析（所有警告与提示信息均视作致命错误）
dart analyze --fatal-infos

# 4. 执行本地离线单元测试套件（共 37 项测试）
dart test -r expanded

# 5. 模拟执行 pub.dev 发布前置检查
dart pub publish --dry-run
```

> [!NOTE] 离线测试覆盖范围
> 离线测试套件完全基于内存 Mock HTTP/TLS 本地服务器和虚拟 DNS 记录运行，不依赖公网环境。核心验证点涵盖：
> - HTTP 状态码、响应头解析与流式响应正文接收
> - 请求上传体积限制与内存缓冲保护
> - 重定向安全策略（严防 HTTPS 降级明文，跨域重定向自动剥离敏感 Header）
> - 流式传输的主动暂停/恢复与原生队列背压控制
> - 请求级超时边界、并发请求有序排队与中途取消中断
> - 客户端关闭时的状态机正确释放
> - 自定义私有 PKI 信任根隔离与域名匹配校验
> - ECH 闭门失败原则（Fail-closed）与不可用公开名的前置拦截
> - 预编译 SDK 归档散列校验、离线安全提取与本地被篡改文件的自愈修复
> - 消息端口投递、消费确认额度及 isolate group 关闭时的清理

---

## 2. 可选的 Live 真实公网测试

`test/live_ech_test.dart` 用于与公网真实运行的 HTTPS/ECH 生产端点进行端到端全链路联调。由于公网环境和 DNS 记录存在动态性，该测试默认跳过，仅当配置了特定环境变量时才主动开启。

### 环境变量配置表

| 环境变量 | 作用说明 |
| :--- | :--- |
| `ECH_TEST_URL` | 目标 HTTPS 地址（必须返回 HTTP 200）。配置后即启用 Live ECH 测试。 |
| `ECH_TEST_CONFIG` | Base64 编码的 `ECHConfigList`。可传入有效配置测试正常握手，或传入过期配置验证服务端的认证重试能力。设置 `ECH_TEST_URL` 时**必填**。 |
| `ECH_TEST_ADDRESSES` | *(可选)* 逗号分隔的目标物理 IP 列表（如 `104.16.132.229,104.16.133.229`）。若不配置，则由底层自动解析目标 DNS。 |
| `ECH_TEST_PROXY` | *(可选)* HTTP CONNECT 代理地址（如 `http://127.0.0.1:7890`）。 |
| `ECH_TEST_EXPECT_RETRY` | 设为 `1` 时，要求服务端必须触发一次合法的 TLS 认证重试方可通过测试。 |
| `ECH_TEST_SHA256` | *(可选)* 预期的响应体 SHA-256 散列值（16 进制），用于校验数据完整性。 |
| `ECH_TEST_BYTES` | *(可选)* 预期的响应体精确字节数。 |
| `ECH_TEST_TRUST_URL` | *(可选)* 独立测试自定义信任根隔离性。指定任意公网正常 HTTPS 地址，测试将通过强制替换根证书库断言其握手必须失败。 |

### 运行测试示例

**Windows (PowerShell):**
```powershell
$env:ECH_TEST_URL = "https://crypto.cloudflare.com/cdn-cgi/trace"
$env:ECH_TEST_CONFIG = "AED+DQA85wAgACD...AAA="
$env:ECH_TEST_EXPECT_RETRY = "0"
dart test test/live_ech_test.dart -r expanded
```

**Linux / macOS (Bash):**
```sh
export ECH_TEST_URL="https://crypto.cloudflare.com/cdn-cgi/trace"
export ECH_TEST_CONFIG="AED+DQA85wAgACD...AAA="
export ECH_TEST_EXPECT_RETRY="0"
dart test test/live_ech_test.dart -r expanded
```

### 动态发现交互脚本

您还可以直接使用附带的完整发现示例脚本 `example/ech_http_example.dart`：

```sh
dart run example/ech_http_example.dart https://crypto.cloudflare.com/cdn-cgi/trace https://cloudflare-dns.com/dns-query
```

配合 `ECH_PROXY`、`ECH_CONFIG_DOMAIN` 或 `ECH_ADDRESSES` 环境变量，可快速验证各类代理与共享 CDN 路由配置。

---

## 3. 预编译原生 SDK 的更新与维护

`ech_http` 依赖 4 个独立的公开构建仓库为 14 个目标平台与架构打包发布预编译 SDK：

- [libechhttp-win32-build](https://github.com/ech-research/libechhttp-win32-build/releases)（Windows: x64, arm64, ia32）
- [libechhttp-darwin-build](https://github.com/ech-research/libechhttp-darwin-build/releases)（macOS / iOS: x64, arm64）
- [libechhttp-android-build](https://github.com/ech-research/libechhttp-android-build/releases)（Android: arm64-v8a, armeabi-v7a, x86_64, x86）
- [libechhttp-linux-build](https://github.com/ech-research/libechhttp-linux-build/releases)（Linux: x64, arm64）

### 升级预编译依赖版本

当 libcurl、BoringSSL 源码更新或编译参数调整时：

1. 在上述 4 个构建仓库中触发 GitHub Actions 并发布新的 Release 版本。
2. 在本项目根目录下运行维护脚本，填入经过评审的新 Release 标签：
   ```sh
   python tool/update_prebuilt.py win32=v0.1.1 darwin=v0.1.2 android=v0.1.1 linux=v0.1.1
   ```
   *(要求本地装有 Python 3.9+ 且具备经过身份授权的 GitHub CLI `gh`)*。
3. 检查并核对 `lib/src/build_support/dependencies.json` 中自动更新的下载链接与 SHA-256 散列值。
4. 提交变更并触发全平台 CI 流水线验证构建钩子。

> [!CAUTION] 资产不可篡改原则
> 严禁在 GitHub Release 既有 Tag 下覆盖或重传已被引用的资产文件。若依赖需修复，必须递增发布新的语义化版本 Tag（如 `v0.1.2`）。

### 更新内置 Mozilla CA 证书库

内置的根证书库文件位于 `src/cacert.pem`。

更新步骤：
1. 从 curl 官方发布页面获取最新的 CA 快照：[curl.se/docs/caextract.html](https://curl.se/docs/caextract.html)。
2. 覆盖替换 `src/cacert.pem`。
3. 重新计算该文件的 SHA-256 散列：
   ```sh
   sha256sum src/cacert.pem
   ```
4. 在以下文件中同步更新该散列值与快照日期：
   - `THIRD_PARTY_NOTICES.md`
   - `src/ca_bundle.h.in`
5. 执行 `dart test` 验证本地 TLS 证书握手校验无误。

---

## 4. 多平台持续集成（CI）矩阵

项目的 GitHub Actions 流水线（`.github/workflows/ci.yml`）涵盖了多平台验证：
- Windows 环境（MSVC x64 原生构建、arm64/ia32 交叉构建）
- Linux 环境（glibc x64 与 arm64 构建及测试）
- macOS 环境（Intel x64 与 Apple Silicon arm64 构建及测试）
- Android 构建（Flutter 打包 arm64、arm、x64、x86 APK）
- iOS 构建（C++ 桥接编译及 Flutter `--no-codesign` 打包）

发布新版本前，确保 CI 所有任务绿灯通过。具体覆盖范围详见 [doc/verification.zh-CN.md](verification.zh-CN.md)。

---

## 5. 发布检查清单（Release Checklist）

正式将版本推送到 pub.dev 之前的核查清单：

1. **版本号统一性**：
   - 更新 `pubspec.yaml` 中的 `version` 字段（遵循语义化版本规范）。
   - 在 `CHANGELOG.md` 中以清晰严谨的条目记录更新要点。
   - 同步更新中英文 `README` 中的示例版本号。
2. **测试私钥豁免核验**：
   - `test/fixtures/localhost-key.pem` 是用于本地测试的公开密钥对，确认其在 `pubspec.yaml` 的 `false_secrets` 中正确登记，避免被 pub.dev 凭据扫描误拦截。
3. **打包文件清单核查 (`--dry-run`)**：
   - 执行：
     ```sh
     dart pub publish --dry-run
     ```
   - 仔细审查终端输出的文件打包列表：
   - **必须包含**：`lib/`（含 `src/build_support/prebuilt.dart` 和 `src/build_support/dependencies.json`）、`hook/build.dart`、`src/`（桥接代码、CMake 脚本、`cacert.pem` 及协议文件）、`LICENSE`、`README.md`、`CHANGELOG.md`、`THIRD_PARTY_NOTICES.md`。
   - 辅助脚本和数据应放在保留的 `hook/` 目录之外；pub.dev 会在上传时检查钩子文件名。
   - **严禁包含**：`.dart_tool/` 缓存、构建生成的临时原生目标、下载的 SDK 压缩包、测试日志文件或 IDE 本地配置（`.vscode/`、`.idea/`）。
4. **正式发布**：
   - 确认所有审查项无误后，由拥有发布权限的维护者在本地执行：
     ```sh
     dart pub publish
     ```
   *(注：CI 流水线不包含自动发布操作，必须由维护者在核审后的 Git Commit 上手工执行发布)*。
