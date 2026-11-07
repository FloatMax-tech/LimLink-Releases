# LimLink

> LimLink is a local-network file transfer app for iPhone, iPad, Mac, Windows and Android.  
> This repository contains the source code, published under the **PolyForm Noncommercial 1.0.0** license.

LimLink 让同一局域网里的设备直接互传文件。文件不经过开发者服务器，不需要账号，出于稳定性考虑，目前单文件上限为 **5 GB**，并在接收端完成 SHA-256 校验后保存。

- 官网：<https://limlink.floatmax-tech.com>
- iPhone / iPad：<https://apps.apple.com/jp/app/limlink/id6826498808>
- 安装包与发布说明：<https://github.com/FloatMax-tech/LimLink-Releases>
- 支持：<limlink@floatmax-tech.com>

当前公开源码对应 **1.0.1**。

## 功能

- iPhone、iPad、Mac、Windows、Android 五端互传
- 同一局域网内自动发现设备，文件点对点传输
- 未绑定设备逐文件确认；绑定设备可自动接收，随时可解绑
- 单文件当前上限 5 GB（出于稳定性考虑），按 1 MiB 分块，增量 SHA-256
- 接收端确认、校验并保存成功后才报告完成；同名文件不覆盖
- 无账号、无广告、无分析追踪、无云端文件中转

## 平台

| 平台 | 实现 | 目录 |
| --- | --- | --- |
| iPhone / iPad | SwiftUI + Bonjour + 共享 Swift SDK | [`apple/LimLink-iOS`](apple/LimLink-iOS) |
| Mac | SwiftUI + Bonjour + 共享 Swift SDK | [`apple/LimLink-mac`](apple/LimLink-mac) |
| Windows | .NET 10 + WPF + DNS-SD + TLS 1.3 | [`windows`](windows) |
| Android | Kotlin + Compose + NsdManager | [`android`](android) |
| 协议核心 | Rust（CPace 邀请握手、状态机、测试向量） | [`core`](core) |

当前客户端的文件收发使用各平台原生 TLS 1.3 实现；Rust 核心保留用于协议、邀请握手和测试向量，不是当前客户端传输流程的运行时依赖。

## 技术参考

架构、发现、TLS、文件传输、设备绑定、安全边界和构建方式见：

- [TECHNICAL.md](TECHNICAL.md)
- [设备绑定协议 v1](docs/protocol/device-binding-v1.md)
- [Rust 核心说明](core/README.md)

## 构建

各平台需要对应的原生工具链。完整命令和验收边界见各目录 README。

### Android

需要 JDK 21、Android SDK 36（含 Build-Tools 36）：

```bash
cd android
./gradlew assembleDebug check
```

### Apple

需要 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46：

```bash
cd apple/LimLink-iOS
xcodegen generate
xcodebuild test -project LimLinkIOS.xcodeproj -scheme LimLinkIOS \
  -destination 'platform=iOS Simulator,name=iPhone 16'

cd ../LimLink-mac
xcodegen generate
xcodebuild test -project LimLinkMac.xcodeproj -scheme LimLinkMac \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO
```

### Windows

需要 .NET 10 SDK：

```powershell
cd windows
dotnet build LimLink.slnx
dotnet test --project tests/LimLink.Core.Tests/LimLink.Core.Tests.csproj
```

### Rust core

需要 Rust stable（1.85+）：

```bash
cd core
cargo test -p limlink-core
cargo test -p limlink-core-testvectors
```

## 仓库结构

```text
apple/          iOS、macOS 客户端与共享 Swift SDK
android/        Android 客户端、UI 与传输库
windows/        .NET/WPF 客户端与共享 .NET 核心
core/           Rust 协议核心、C ABI、测试向量
tools/          跨端互操作探针、品牌资源生成
docs/protocol/  设备绑定协议
```

## 安全边界

- 只在可互通的局域网内传输；远程链接下载、云端中转当前关闭。
- 使用 TLS 1.3 双向认证，并把实际 TLS 证书与发现信息中的 SPKI SHA-256 指纹绑定。
- 设备名称只是显示名，不代表经过核验的真实身份；绑定前请确认是你认识的设备。
- 首次使用信任的是所选设备的 TLS 密钥，不提供 SAS/验证码比对，也不防御首次发现时的恶意替换。
- 已绑定设备仍需双方应用运行；解绑不会撤回已经保存的文件或取消已接受的传输。
- 密钥和签名材料不进入本仓库。请勿在 issue 中提交私钥、密码、验证码或客户文件。

安全问题请发邮件到 <limlink@floatmax-tech.com>，不要先开公开 issue。

## 已知限制

- 不支持文件夹传输或断点续传
- iPhone / iPad 传输时需要保持应用在前台
- 普通请求与等待确认默认有 120 秒超时；最终校验和保存最长 30 分钟
- 当前不提供跨互联网下载链接、远程中继或云端存储
- 各平台的文件选择、保存位置和系统权限行为存在差异，以对应平台说明为准

## 许可证

源码采用 **PolyForm Noncommercial License 1.0.0**：

- 允许个人、研究、教育、慈善等非商业用途
- **商业使用需要单独书面授权**，请联系 <limlink@floatmax-tech.com>
- 这不是 OSI 定义的开源许可证，而是源码可见（source-available）的非商用许可证
- LimLink 名称、Logo、应用图标、截图和商店素材不随源码授权
- 第三方依赖继续适用其各自许可证

完整条款见 [LICENSE](LICENSE)，品牌与第三方说明见 [NOTICE](NOTICE)。

Copyright © 2026 Hangzhou FloatMAX Technology Co., Ltd. (杭州浮点极限科技有限公司).
