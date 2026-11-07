# LimLink Mac

原生 macOS 14+ SwiftUI/AppKit 客户端，已接入 `../LimLinkKit` 和 `../LimLink-iOS/Support`。临时 bundle id 为 `com.limlink.dev`。

- 单文件 0–5,000,000,000 字节，发送前创建磁盘快照并增量计算 SHA-256，每块最多 1,048,576 字节。
- Bonjour `_limlink._tcp` 发现；过滤本机和无效指纹，按所选发现记录自动绑定 TLS 证书，无人工指纹核对。
- 接收卡片显示同一 TLS 连接声明的发送者名称、文件名、大小，明确接收或拒绝。连接、指纹和文件元数据必须与同意记录一致。
- 接收最多 4 个连接，等待确认和普通请求无进展超时 120 秒；验证摘要后才发布文件。发送端等待最终校验/保存答复的总预算为 30 分钟，可随时取消，兼容较慢外接盘的发布过程。保存失败不会向发送端报告成功。
- 默认保存到“下载”，可通过原生文件夹选择器记住安全作用域书签。外接卷先复制到目标目录内的隐藏暂存位置，加上隔离标记，再由共享文件存储完成不覆盖重名文件的发布。启动和切换目录时清理本应用遗留的 UUID 暂存文件。
- 支持自定义设备名、原生文件选择、取消发送、真实发送进度、Dock/菜单栏进度，以及本次实际保存文件的 Finder 定位。接收端当前显示真实接收状态和不定量进度；SDK 尚未公开逐块接收字节回调。
- 关闭窗口后继续监听，退出应用时停止连接。远程链接未启用；模拟进度引擎只用于旧进度组件的单元测试，不编入应用。

生成工程（XcodeGen 2.46.0）并测试：

```sh
cd apple/LimLink-mac
xcodegen generate
xcodebuild test \
  -project LimLinkMac.xcodeproj \
  -scheme LimLinkMac \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/limlink-mac-derived \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM=
```

在 Xcode 里运行应用时，Debug 默认使用开发团队 `J8PZU3W5VL` 的 Apple Development 签名。CI 可覆盖为临时签名进行构建和逻辑测试。实际重复运行应使用稳定开发证书：重建后的临时签名可能无法读取上一次运行创建的 macOS 登录钥匙串身份，表现为启动等待。不要为测试删除用户已有钥匙串条目。

App Store 与 Developer ID 导出配置保留在 `ExportOptions/`。应用声明本地网络用途、Bonjour 服务、沙盒网络收发、下载目录和用户选择目录权限，不使用额外组播 entitlement，也不含自动更新器。

2026-10-18 验证记录：35 项 Mac 测试通过，覆盖书签回退、路径/重名、隔离标记、连接归属同意、启动暂存清理和 5 GB 元数据边界；真实 Network.framework TLS 1.3 测试传输了 2,097,169 字节，验证了同意后传输、Mac 发布适配器、文件内容及断开后的暂存清理。已启动开发证书签名的验证应用，检查原生文件选择和真实 TLS 接收请求（发送者名称/文件/大小/接收按钮）。

运行环境限制：本机“下载”目录枚举阻塞导致该次 GUI 接收未完成最终保存；独立临时目录中的发布回归通过。该机器上 Bonjour 浏览器进入 ready，但尚未在独立浏览工具中观察到应用公告；已核对实际 plist/签名权限，未找到 PolicyDenied/NoAuth 日志。此状态不算 Bonjour 或跨设备验收通过。尚未进行 Mac GUI 与真机 iPhone、Windows 或 Android 的 5 GB 传输验收。
