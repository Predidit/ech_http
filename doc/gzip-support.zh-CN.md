# gzip 响应支持

`ech_http` 0.2.0 使用固定版本的静态 zlib 1.3.2，在原生工作线程上进行 gzip 流式解压。
对外的协商、响应头、长度和压缩状态约定参考 Dart `HttpClient` 与 `package:http` 的 `IOClient`。

## 请求与响应约定

- 默认发送 `Accept-Encoding: gzip`；调用方显式提供的值优先，空值也会保留。
- `EchClient(autoUncompress: true)` 为默认配置，仅在 `Content-Encoding` 的值为 `gzip` 时自动解码。
- `autoUncompress: false` 保留原始正文，但仍默认协商 gzip。需要请求未压缩响应时，显式设置 `Accept-Encoding: identity`。
- 是否解码由响应编码决定；即使请求指定 identity，服务端仍返回 gzip 时，自动模式也会解码。
- `deflate`、`br`、`x-gzip`、复合编码等不自动处理；没有 `Content-Encoding` 的 `.gz` 文件原样返回。
- 请求正文不会自动压缩。调用方预先压缩并设置 `Content-Encoding: gzip` 的正文仍原样上传。
- Range 请求与普通请求使用相同协商规则，与 Dart 一致。需要按编码后的字节偏移保存数据时，请设置 identity 或关闭自动解码。

## 长度与响应头

所有响应头均保留服务器原值，**不删除或改写 Content-Encoding、Content-Length**。

| API | 正文 | contentLength 属性 | Content-Length 响应头 |
| --- | --- | --- | --- |
| `send()` 的 `EchResponse` | 解压后的流（启用解码时） | 传输的编码正文长度；未知时为 null | 原始传输长度 |
| `get()` / `post()` 的完整 `http.Response` | 解压后的字节 | `bodyBytes.length` | 原始传输长度 |
| `autoUncompress: false` | 原始字节 | 对应上述 API 的既有语义 | 原始传输长度 |

例如，1 KiB 的 gzip 正文解压后为 10 KiB：`send()` 的 `contentLength` 为 1 KiB，
读取响应流可得到 10 KiB；`get()` 的 `contentLength` 为 10 KiB，但两者的
`headers['content-length']` 均仍是服务器发送的 1 KiB。

`EchResponse.compressionState` 使用 Dart 的 `HttpClientResponseCompressionState`：
gzip 响应在自动模式为 `decompressed`，原样模式为 `compressed`，其他编码为
`notCompressed`。该值表示依据头部选择的解码策略，不是正文完整性校验结果；
HEAD、204、304 等无正文响应不会凭空生成正文。

参考：[Dart autoUncompress](https://api.dart.dev/dart-io/HttpClient/autoUncompress.html)、
[Dart compressionState](https://api.dart.dev/dart-io/HttpClientResponse/compressionState.html)。

## 原生实现与限制

数据经过 libcurl 接收、原生 zlib 解码、响应大小检查、消息投递额度控制，最后进入 Dart 响应流。

桥接层关闭 libcurl 的通用内容解码，并在响应头明确指定 gzip 时调用 zlib。
这样既能保持 Dart 对其他编码的原样返回行为，又支持拼接的 gzip member。
每次解码输出最多 16 KiB；输出立即进入原有背压通道，无需提前解压完整响应。

- `maxResponseBytes` 限制交付正文的总字节数，自动模式下为解压后大小，原样模式下为编码后大小。
- 256 KiB 额度限制尚未确认的原生正文消息，自动模式下同样按解压后大小计数；这不是整个请求所有内存的总上限。
- 暂停、恢复、取消和客户端关闭继续沿用原有请求生命周期。解码失败不重放已经收到响应头的请求。
- 损坏头部、CRC 错误、尾随无效数据或不完整压缩流通过响应流报告 `EchException`，原生错误码为 61。
- 实现会严格检查非空压缩流是否结束；这比某些 Dart SDK 对缺失 gzip 尾部的容忍行为更严格。
- 流式失败前可能已经交付部分数据。需要完整性保证时，应等待正文流正常结束再使用最终结果。

## 固定依赖与发布

四个 SDK 构建仓库均固定 zlib 源码版本和 SHA-256，构建静态库并随 SDK 提供
匹配头文件、CMake 导入目标及许可证。编译使用目标工具链，不依赖宿主系统的 zlib。

| 构建仓库 | gzip SDK 版本 | 目标数 |
| --- | --- | ---: |
| [Windows](https://github.com/ech-research/libechhttp-win32-build) | v0.1.1 | 3 |
| [Linux](https://github.com/ech-research/libechhttp-linux-build) | v0.1.1 | 2 |
| [Android](https://github.com/ech-research/libechhttp-android-build) | v0.1.1 | 4 |
| [Darwin](https://github.com/ech-research/libechhttp-darwin-build) | v0.1.2 | 5 |

主工程固定各 SDK 的下载地址和归档摘要，并检查 zlib 版本、源码摘要、静态库、头文件及许可证。
缓存内容被修改时，继续通过已校验的归档修复。客户端初始化也要求原生 libcurl 报告 zlib 能力。

## 最终二进制体积

Windows x64 使用同一 MSVC 14.51.36231、Release、静态 CRT（`/MT`）配置，
分别编译改造前提交 `434472d` 与 gzip 实现提交 `f77946e`，各自使用其固定的正式 SDK：

| 产物 | 改造前 | gzip 实现 | 增量 |
| --- | ---: | ---: | ---: |
| `ech_http.dll` | 2,075,136 字节 | 2,111,488 字节 | 36,352 字节（35.5 KiB，1.75%） |
| 单 DLL ZIP（Deflate level 9） | 1,019,714 字节 | 1,044,442 字节 | 24,728 字节（约 24.1 KiB） |

这是 zlib 静态链接与桥接解码逻辑合计的最终增量，不是 SDK 静态库归档大小，
也不代表其他架构或应用安装包的精确增量。

## 验证

`test/gzip_test.dart` 使用本地服务与 `IOClient` 对照，覆盖默认及自定义协商、开关、
原始响应头、流式及完整正文长度、其他编码、空正文、HEAD/204/304、Range 和重定向。
另覆盖逐字节输入、拼接 member、解压后超限、损坏及截断数据、暂停/恢复/取消及并发槽释放。
`test/native_events_test.dart` 直接验证 gzip 解压后未确认消息仍受 256 KiB 额度约束。

SDK CI 对所有目标执行编译和打包后的导入目标链接检查；匹配架构的桌面 runner
还执行 ECH/zlib 能力检查和 gzip 解码探针。主工程平台 CI 验证桌面运行时与 Android/iOS 打包。
