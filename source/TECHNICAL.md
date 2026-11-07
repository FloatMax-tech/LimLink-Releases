# LimLink 技术参考

本文说明 LimLink 1.0.1 的整体架构、发现与传输协议、安全边界、构建方式和已知限制。实现细节以仓库代码和协议文档为准。

## 1. 目标与边界

LimLink 解决的是“同一局域网内，把文件从一台设备直接送到另一台设备”：

- 不经过开发者服务器，不提供云盘中转
- 不需要账号、广告或分析追踪
- 出于稳定性考虑，单文件当前上限 5 GB（5,000,000,000 字节）
- 未绑定设备逐文件确认；绑定设备可自动接收
- 接收端校验并保存成功后才报告完成
- 远程链接下载和跨互联网中继当前关闭

## 2. 仓库结构

| 路径 | 内容 |
| --- | --- |
| `apple/LimLink-iOS` | iPhone / iPad SwiftUI 客户端 |
| `apple/LimLink-mac` | macOS SwiftUI 客户端 |
| `apple/LimLinkKit` | Apple 客户端共享的 Swift 传输 SDK |
| `windows` | .NET 10 / WPF Windows 客户端和共享 .NET 核心 |
| `android` | Kotlin / Compose Android 客户端、UI 与传输库 |
| `core` | Rust 协议核心、C ABI、测试向量 |
| `tools` | 跨端互操作探针和品牌资源生成 |
| `docs/protocol` | 设备绑定等协议契约 |

各客户端使用同一套产品行为和传输语义，但网络、TLS、文件系统和权限使用各平台原生实现。

## 3. 客户端架构

### Apple

- iPhone / iPad：SwiftUI，Bonjour 发现附近设备，使用共享 `LimLinkKit`
- Mac：SwiftUI，Bonjour 发现，共享 `LimLinkKit`，支持接收目录选择和 Dock 进度
- 身份密钥保存在系统钥匙串；不启用钥匙串同步
- iPhone / iPad 传输时需要保持应用在前台

### Windows

- .NET 10 + WPF，Windows 11
- DNS-SD `_limlink._tcp.local` 发现
- Kestrel / `SslStream` 承载 TLS 1.3
- 身份和设置位于 `%LOCALAPPDATA%\LimLink`
- 生产 PFX 使用 DPAPI CurrentUser 保护；测试保护器只存在于测试项目

### Android

- Kotlin + Jetpack Compose
- `NsdManager` 发现，`AndroidKeyStore` 保存身份密钥
- `MediaStore` / SAF 处理保存位置
- 支持多选文件逐个发送；前台服务承载传输

### Rust core

`core/` 保留 CPace 邀请握手、状态机、票据核销和测试向量。当前五端客户端的文件收发使用各平台原生 TLS 1.3 实现，Rust 核心不是当前传输流程的运行时依赖。

Rust 核心的详细约束见 [`core/README.md`](core/README.md)。

## 4. 发现与连接

- 服务类型：`_limlink._tcp.local`
- TXT 信息包含 `pv=1.0`、`fp`（设备公钥指纹）、`dt`（设备类型）和 `app=limlink`
- 各端过滤自己和无效身份
- 发送方从发现记录取得候选地址，并优先使用同子网地址
- 连接使用 TLS 1.3 双向证书认证
- 发送方把实际 TLS 证书与所选发现记录的 SPKI SHA-256 指纹绑定，防止连接到错误的同名设备
- 每次文件传输使用一条 TLS/HTTP 1.1 连接
- 设备名称由用户设置，只有显示意义，不代表经过核验的真实身份

## 5. 文件传输

- 单个文件当前上限 5,000,000,000 字节（5 GB，出于稳定性考虑）；支持空文件
- 分块上限 1,048,576 字节
- 发送端使用私有快照，避免传输过程中源文件变化
- 接收端先写入隐藏暂存目录，校验通过后再原子发布
- 增量 SHA-256 校验；发送完成不等于接收成功，必须等接收端校验并保存
- 同名文件自动改名，不覆盖已有文件
- 普通请求和等待接收确认默认 120 秒超时
- 最终校验和持久化保存单独允许最多 30 分钟
- 取消、断线、拒绝会清理私有暂存文件；启动时回收遗留暂存

## 6. 设备绑定 v1

设备绑定是独立的“先选择设备、再由对方确认”的流程，不复用文件传输中的临时信任：

- 独立配对连接，复用双向 TLS 和应用门 `limlink`
- 控制接口位于 `/limlink/v1/pair`
- 发起方选择绑定；只有接收方看到接受/拒绝
- 绑定令牌是 32 字节系统随机数，只通过配对连接传输，不写日志
- 配对请求固定 120 秒截止，不因轮询延长
- 同一设备同时只允许一个进行中的配对尝试
- 每 60 秒最多接受 3 个新的入站尝试；幂等重试不重复计数
- 只有接收方确认后才持久化；完成时双方各自保存绑定关系
- 每个文件连接都必须携带与当前 TLS 对端、当前本机身份和本地有效记录匹配的 `bindingId`
- 单边记录、旧版客户端、身份密钥变化或存储失败都回退到逐文件确认
- 解绑只影响本机后续自动接收，不撤回已保存文件或取消已接受的传输

完整契约见 [`docs/protocol/device-binding-v1.md`](docs/protocol/device-binding-v1.md)。

安全边界：绑定信任的是所选设备的 TLS 密钥，属于首次使用信任；没有 SAS/验证码比对，也不防御首次发现阶段的恶意替换。名称可以重复或仿冒，绑定前应确认设备。

## 7. 密钥与隐私

- 不要求账号，不收集使用分析，不运营文件中转服务器
- Apple 身份密钥在系统钥匙串；Android 在 `AndroidKeyStore`；Windows 使用 DPAPI 保护的本地文件
- 文件内容只在本机内存、私有暂存和用户选择的接收位置之间流动
- 接收端保存成功后才会发布文件；失败不会留下可见的半成品
- 设备名、设备类型、连接地址和公开身份指纹会出现在局域网发现信息中
- 远程链接下载、云端中转和远程撤回当前不提供
- 官网隐私政策：<https://limlink.floatmax-tech.com/privacy.html>

## 8. 构建与测试

### Android

需要 JDK 21、Android SDK 36（含 Build-Tools 36）：

```bash
cd android
./gradlew assembleDebug check
```

`check` 包含单元测试、lint 和主源码中文扫描。

### Apple

需要 Xcode、XcodeGen 2.46：

```bash
cd apple/LimLink-iOS
xcodegen generate
xcodebuild test \
  -project LimLinkIOS.xcodeproj \
  -scheme LimLinkIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16'

cd ../LimLink-mac
xcodegen generate
xcodebuild test \
  -project LimLinkMac.xcodeproj \
  -scheme LimLinkMac \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO
```

Mac App Store 和 Developer ID 的导出配置在 `apple/LimLink-mac/ExportOptions/`；没有签名证书时 CI 不导出。

### Windows

需要 .NET 10 SDK：

```powershell
cd windows
dotnet build LimLink.slnx
dotnet test --project tests/LimLink.Core.Tests/LimLink.Core.Tests.csproj
```

Windows 运行时验收需要 Windows 11；在 macOS 上交叉构建不能替代真实 TLS、防火墙、DPAPI 和局域网验收。

### Rust core

需要 Rust stable（1.85+）：

```bash
cd core
cargo test -p limlink-core
cargo test -p limlink-core --features test-rng
cargo test -p limlink-core-testvectors
python3 vectors/ref_impl.py --check
```

`core/` 的测试向量需要系统 `libsodium`；测试构建和发布构建不能混用。

## 9. 发布与分发

- iPhone / iPad：App Store，iOS / iPadOS 17+
- Mac：官网 DMG，macOS 14+，Apple 芯片 / Intel
- Windows：官网安装包，x86_64 / ARM64
- Android：官网 APK，Android 10+
- GitHub Releases 保存同版本安装包和 SHA-256 校验值
- 签名密钥、证书和商店凭据不进入本仓库

官网：<https://limlink.floatmax-tech.com>  
发布页：<https://github.com/FloatMax-tech/LimLink-Releases>

## 10. 已知限制

- 不支持文件夹传输、断点续传或跨互联网中继
- iPhone / iPad 传输时需要保持应用在前台
- 普通请求和等待确认默认 120 秒超时
- Mac App Store、Google Play、Microsoft Store 版本仍在准备中
- 各平台的文件选择、保存位置、后台行为和系统权限存在差异
- 首次发现和首次绑定不能替代对设备真实身份的核验
- 源码采用非商用许可证；商业使用需要单独授权

## 11. 许可证

源码采用 **PolyForm Noncommercial License 1.0.0**。这是源码可见（source-available）的非商用许可证，不是 OSI 定义的开源许可证。

- 允许个人、研究、教育、慈善等非商业用途
- 商业使用需要单独书面授权：<limlink@floatmax-tech.com>
- LimLink 名称、Logo、应用图标、截图和商店素材不随源码授权
- 第三方依赖继续适用其各自许可证

完整条款见 [`LICENSE`](LICENSE)，品牌与第三方说明见 [`NOTICE`](NOTICE)。
