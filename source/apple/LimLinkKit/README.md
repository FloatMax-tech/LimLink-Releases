# LimLinkKit

无界面的 Swift Package，供 LimLink 以及其他宿主嵌入。支持 iOS 17+、原生 macOS 14+（不是 Mac Catalyst）。Swift 6 语言模式。Kit 通过共享观察器管理生命周期，不包含界面文案；宿主自己把错误码映射成文字。

临时 bundle id 是 `com.limlink.dev`。本仓库的 Mac 应用会单独走 `apple/LimLink-mac/**` 的工作流，并把本包当作库来用。

## 布局

| 路径 | 作用 |
| --- | --- |
| `Sources/LimLinkCoreLogic` | 指纹、证书 DER、TXT、端口策略、`app` 过滤、诊断记录、HTTP/1.1 单文件传输。Linux 上可以编译和测试。 |
| `Sources/LimLinkKit` | Keychain 身份、Network.framework 的 TLS 监听/连接、Bonjour 浏览、在已有 TLS 连接上收发 HTTP。仅 Apple 平台。 |
| `Tests/LimLinkCoreLogicTests` | `swift test` 在 Linux 上运行的用例。 |
| `Tests/LimLinkKitTests` | 回环 TLS、端口回退、Keychain。Bonjour 浏览默认跳过。 |

`Package.swift` 在 Linux 上不声明 `LimLinkKit` 目标。宿主只需要 `import LimLinkKit`；该模块 `@_exported import LimLinkCoreLogic`。

## 公开 API

- `LimLinkConfiguration.make(app:allowedPeerApps:bundleIdentifier:deviceName:deviceType:)`：宿主自己的 `app`。缺省允许列表是互通组 `{limlink, casecheck}`。宿主传入的列表只能把这个组收窄，并且必须包含自己，否则 `allowListExcludesSelf`。
- `LimLink.clearDiagnosticsLog()`：清掉本机的不匹配记录。记录只留在本机，最多 100 条，超过 30 天在写入和读取时丢掉。没有上传接口。
- `SingleFileClient` / `SingleFileReceiver`：一个文件的 HTTP/1.1 请求和校验。Apple 上 `FramedExchange` 把这些帧写到已经建好的 TLS 连接。
- `SingleFileService`：`PendingSession` 提供已验证的文件名、声明大小，以及绑定当前 TLS 连接的 `senderName`（hello alias，显示名不证明对端所有者身份）。`decide` 返回本次决定是否仍可应用；它不会自动信任设备或接受文件。`serve` 可设置 `HTTPRequestLimits`、空闲超时和每条连接独立的回调。异步 `onPublished` 回调须保存校验后的文件并返回实际落盘文件名；成功回复会等待此回调，写入失败返回 `E_WRITE_FAILED`。不传这个回调时，原有同步通知行为保留。
- 接收宿主可设置 `maximumRetainedSessions` 限制保留的会话数，并选择 `discardSessionsOnDisconnect` 清理该连接创建的会话及文件字节；清理后不能恢复这些会话。正式 iOS 应用使用 4 个保留会话、16 KiB 请求头、1 MiB 请求体、5 GB 文件上限、120 秒空闲超时，断开后重新发送。Kit 的缺省参数保持原有会话保留方式。
- 会话和幂等键始终绑定实际 TLS 指纹；启用 `discardSessionsOnDisconnect` 时还绑定创建它的连接。其他设备或连接不能读取、完成或控制该会话。缺省保留模式允许同一 TLS 身份重连恢复。
- 异步保存尚未完成时，其他请求不能观察到传输成功；保存失败会先清除会话。同一临时目录的初始化、写入、删除和过期清理共用事务锁，跨实例和符号链接路径也保持一致；目录登记表更新同样串行。后台活动状态采用有序通知，防止旧清理覆盖新传输。
- 发送宿主可向 `SingleFileExchange.run` 传入 `HTTPResponseLimits`、`idleTimeout`、`approvalTimeout` 和 `completionTimeout`。正式 iOS 应用限制 JSON 响应体为 64 KiB、响应头为 16 KiB，普通请求设置 120 秒空闲超时。首次等待接收方同意另有默认 120 秒的总时限，连续 202 回复不会重置它；获准后的文件传输和恢复轮询不受这个总时限限制。最终 `POST .../complete` 为校验与慢速磁盘发布单独提供默认 30 分钟的总时限，期间仍可取消；其他请求不延长。
- 对端报告的偏移必须是文件范围内的精确整数；缺失或无效的 PUT 确认不会推进进度。发送完成须收到 HTTP 200、明确的校验成功，以及匹配会话、文件、长度和落盘名称的完成报告。
- 监听器进入失败或取消状态时，当前和后续 `nextConnection` 都返回终止原因；停止时关闭尚未交给宿主的连接，后续取消不会覆盖最初的故障。
- `KeychainDeviceIdentity`：P-256 私钥放进钥匙串，不同步 iCloud。证书是手写 DER 的自签 `CN=limlink`。指纹是 SubjectPublicKeyInfo 的 SHA-256，base64url、无填充、43 字符；`displayGrouped` 取前 16 个字符、每 4 个一组，没有省略号。正式 iOS 收发流程自动绑定所选设备的连接指纹，无需人工核对；完整指纹仅保留在本机身份诊断页。
- `LimLinkListener` / `LimLinkConnection`：TLS 1.3（最小和最大都是 1.3），双向证书，只按指纹信任，ALPN `http/1.1`，`allowFastOpen = false`，会话恢复和票据都关掉。端口从 52470 起，依次 +1…+9，然后系统分配。测试连 `127.0.0.1`，不发 Bonjour。监听用普通的 `NWListener(using:on:)`。接收连接回调在 `start` 之前注册；就绪至宿主创建之间到达的连接会暂存并交接。
- `TLSFingerprintPolicy`：`allowListed` 或 `acceptAndReport`。这里没有 `app` 字段。
- `LimLinkBrowser`：使用 `bonjourWithTXTRecord` 浏览 `_limlink._tcp`，同步取得指纹、协议版本和设备类型等 TXT 字段。TXT 预过滤是单向的：不在允许列表里的对端只进诊断列表，不发 `hello`，也不再补探。`NWBrowser` 的 `.changed` 会用新 TXT 把整份名单（含先前被滤掉的）重新过滤，这个过程不建立连接。自己的指纹两边都去掉。互通组内、地址在本机、`app` 不同的对端两边都不列出。
- `AppGate`：先对允许列表，再判本机。不在列表里是 `403 E_APP_MISMATCH`，没有 `detail.reason`。列表内、本机、另一个 `app` 才带 `detail.reason = same_device`。缺省或空的 `app` 当成 `limlink`。`hello` 和 `invite/hello` 仍回 200，并带上自己的 `app`。之后由发起方用 TLS 上的 `app` 再判一次。
- `LimLinkPairingCore` / `UnavailablePairingCore`：配对核心的插口。本里程碑不链接 Rust，也不做 CPace。测试走 `ExplicitFingerprintTrust`。

## 大文件存储与验证

发送方使用 `TransferSource(fileURL:size:sha256Hex:)`，每次 PUT 最多读取 1 MiB，接收确认必须恰好等于该分块末端。摘要使用有界增量计算。内存字节入口仅保留为小数据兼容接口。

接收方传入 `receiveDirectory` 启用磁盘存储，`maximumFileBytes` 最大为 5,000,000,000 字节；`PublishedFile.fileURL` 指向已校验的会话暂存文件，`bytes` 为空。`onPublished` 应移动该 URL 到最终位置并返回实际文件名。清理只针对原暂存路径，不删除已移动的文件。磁盘会话不会进入旧的全量字节持久化队列。每个文件仍必须经 `decide` 同意后才能传输。

`LargeFileStreamingTests` 默认实际传输 32 MiB + 17 字节；设置 `LIMLINK_TEST_5GB=1` 可运行完整 5 GB 测试（需要约 10 GB 可用空间）。2026-10-18 的 macOS 双向 TLS 回环测试已完成 5 GB、逐字节比较和独立摘要校验；这不等于 iPhone 与 iPad 的无线传输实测。

## 依赖和许可证

没有第三方 Swift 包。证书用包内的 DER 编码器，签名用 `SecKeyCreateSignature`。没有 GPL、LGPL 或 MPL 代码。

## 宿主要自己声明的权限

Kit 不代宿主写 Info.plist。要在局域网里宣告或浏览时，宿主加上：

- `NSBonjourServices`：`_limlink._tcp`
- `NSLocalNetworkUsageDescription`

回环上的 TLS 测试不需要这两项。

## `app` 不是安全边界

协议 1.2 只影响设备列表和后续请求要不要继续。信任只看证书指纹。v1 互通组是 `limlink` 和 `casecheck`，两边缺省都允许这一组。比较时只把 ASCII 的 A–Z 折成小写。空字符串和缺字段都是 `limlink`。非空值不去掉首尾空白。宿主自己的 `app` 必须在登记表里，字符集是 `a-z`、`0-9`、`-`，UTF-8 不超过 16 字节。观察到的对端 `app` 字符不合法或超长时，不当成 `limlink`，只是匹配不上允许列表。宿主给的列表先和互通组取交集，不能把自己排除在外。空列表因此是配置错误，不是「谁都不允许」。Kit 不拼显示名：`app` 和 `alias` 分开交给宿主。

## Bonjour 与 CI

GitHub 托管的 macOS runner 上没有人能点「本地网络」隐私提示，新系统又把 Bonjour 宣告/浏览挡在这个提示后面。因此：

- 握手、TLS 版本和端口回退测试连接 `127.0.0.1`，`TransportScope.loopback`，不宣告服务。
- 浏览测试只有在环境变量 `LIMLINK_BONJOUR_TEST=1` 时才跑，超时 8 秒。工作流不设置这个变量，所以 CI 不会停在权限对话框上。

工作流 `.github/workflows/limlinkkit.yml` 不在普通 push 上跑。触发是 `workflow_dispatch`（给人用；云端代理没有 Actions 写权限，调不了），以及非草稿 pull request 的 `ready_for_review` 和 `synchronize`（路径只含 `apple/LimLinkKit/**` 和该工作流文件）。草稿 PR 的 job 会被 `draft == false` 跳过。`concurrency` 按分支取消正在跑的任务。能在 Linux 上跑的纯逻辑测试放在 Ubuntu job。macOS 和 iOS 模拟器都用 `xcodebuild test`。此前归因于运行环境的 POSIX EINVAL 来自监听器启动前缺少接收连接回调，测试探针也有相同错误；已修正并移除监听测试的 CI 跳过开关。SwiftPM 构建目录有缓存。

## Linux 上已经跑过的逻辑

指纹格式、SAS 测试向量、证书 DER 往返、TXT 编解码（含缺省 `app`、`inv` 省略、重复键以后者为准）、实例名按字符截断、端口策略、允许列表（先列表、再本机）、发现结果分区、TXT 变更重过滤、TLS 上的 `app` 与提示/静默、诊断记录的 30 天和 100 条、HTTP/1.1、SHA-256、半截文件、单文件收发、TLS 版本判定、错误码和邀请核心错误映射。需要 Network.framework 的监听与 TLS 用例在 Apple 平台执行，不因 CI 环境而跳过。无宿主的 iOS 模拟器只有在钥匙串实际返回 `errSecMissingEntitlement` 时才跳过依赖身份的测试；监听失败仍是测试失败。

## 文档与仍待验证的行为

这些结论来自 Security / Network 头文件，要等 macOS 和 iOS 模拟器的测试日志才能算在运行时确认：

| 问题 | 文档 | Kit 的做法 |
| --- | --- | --- |
| verify 回调里能否读到协商出的 TLS 版本 | `sec_protocol_metadata_get_negotiated_tls_protocol_version` 存在，但没有写明在 verify 回调里已经填好。 | 只有明确的 1.0/1.1/1.2 才在回调里拒绝。读到 0 就留给 ready 状态；那时不是 `0x0304` 就断开。成功用例打印 `LIMLINK_VERIFY_BLOCK_VERSION`，不因为回调里是 0 而失败。 |
| 0-RTT 默认是否关闭 | 公开开关是 `NWParameters.allowFastOpen`，文档没有写默认值。 | 强制 `false`，并在 early data 被接受时拒绝。测试打印 `LIMLINK_ALLOW_FAST_OPEN_DEFAULT`（改写之前的值），不断言它一定是 false。 |
| 能否关掉票据和恢复 | `sec_protocol_options_set_tls_resumption_enabled` 和 `sec_protocol_options_set_tls_tickets_enabled` 是两个 API。 | 两个都设为 false。第二次连接仍能看到证书，只说明没有把证书隐藏掉，不能证明链路上没有票据。 |
| TLS 1.3 的服务端会不会要客户端证书 | 服务端的 `peer_authentication_required` 默认是 false。 | 监听端设为 true，同时设置本地身份和 challenge 回调。服务端记录到客户端指纹时，日志里有 `LIMLINK_SERVER_SAW_CLIENT_CERT`。 |
| 运行中改 `listener.service` 能否去掉或加上 `inv=1` | 文档允许更新已启动的服务，没有承诺 TXT 立刻生效。 | `setInviting` 会换上新的 TXT，并保留原来的指纹。 |

另外：`sec_protocol_options_set_tls_renegotiation_enabled` 只影响 TLS 1.2 及更早，默认 true。这里仍设为 false。ALPN 可以没有；协商出来的值如果不是 `http/1.1` 就拒绝。指纹取证书里的 SPKI，不用 `sec_protocol_metadata_copy_peer_public_key`（那是原始公钥，不一定是 SPKI）。没有公开 API 能从裸的 `SecKey` + `SecCertificate` 做出 `sec_identity_t`，所以身份必须进钥匙串。未签名的 `swift test` 在 macOS 上可能拿不到数据保护钥匙串（`-34018`），这时会退到传统钥匙串；传统钥匙串不一定遵守「仅本机、不进备份」。iOS 不设置 `kSecUseDataProtectionKeychain`。

## 协议里还没写死的地方

- 密钥算法是「建议 ECDSA P-256」，不是已定。这里用了 P-256。
- 有效期由各端自定。这里是 notBefore = 现在减 1 小时，notAfter = 现在加 10 年。校验不看过期时间。
- 主题和颁发者都是正好 `CN=limlink`。信任不看这个名字，只看指纹。
- 第 13 节的表可能还没有 `E_APP_MISMATCH`。1.2 节定义了它，这里按 1.2 实现。
- 展示用指纹没有协议示例里的省略号；那个省略号只是文档在缩写。
- iOS 可以落到系统分配的端口，因此不使用 `L_PORT_UNAVAILABLE`。浏览器分享端口 52480–52489 只记了常量，本里程碑不监听它们。
- `inv` 只在邀请进行时写成 `1`，否则整项省略，不写 `inv=0`。
