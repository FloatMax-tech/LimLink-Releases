# LimLink 安卓端

Android 10+ 的局域网文件收发客户端。使用 Compose、AndroidKeyStore、TLS socket 和 NsdManager，与当前 Apple SDK 的 `/limlink/v1` 协议对齐；当前 LAN 模式不需要 Rust/JNI。可以一次选择多个文件，客户端会按“每台设备、每个文件”的顺序逐个发送。

## 使用

1. 在同一局域网打开邻连。前台服务保持接收和发现，通知里可停止接收。
2. 先选择一个或多个文件，准备好私有磁盘快照后，再选择附近接收设备；多选设备时会依次发给每台设备。
3. 未绑定的接收方看到该 TLS 连接 hello 的发送设备名、文件名和字节数，选择接收或拒绝；双方绑定完成且当前连接的绑定标识匹配时，可自动接收。
4. 接收同意后才允许写入。校验并保存成功后显示完成；历史只记录本次运行中的真实完成结果。

## 界面（五端统一设计）

- 首页：大文件卡片（未选时虚线环缓慢旋转；选中后粗环画出、文件图标弹出）+ 发送按钮。选择来源用底部面板（照片和视频 / 文件）。
- 选择设备：雷达（同心环 + 信号绿扩散环，中间为品牌标志）+ 设备卡片网格，按设备类型显示图标，逐个上浮出现；点设备即发送。
- 发送进度页：大进度环平滑追赶，等待时四分之一弧旋转；速度、剩余时间、四段步骤条（连接 / 对方同意 / 传输 / 校验保存）；送达时绿环画满、对勾弹出并有涟漪，失败时图标抖动。
- 接收确认：覆盖在所有页面之上的底部面板（不依赖独立的对话框窗口），显示发送者、文件、大小、保存位置和 120 秒倒计时；返回键等同拒绝。应用在后台时改用高优先级通知，可直接接收 / 拒绝。
- 接收中在首页显示带进度环的卡片，完成后显示提示条；接收状态与待发送文件分开保存，接收不会清掉已选好的文件。
- 前台服务通知在传输时显示进度和“取消”按钮。
- 深色模式主按钮为白底黑字；信号绿只用于已就绪、进行中、已送达。系统“移除动画”开启时动效关闭。
- 诊断页显示本机证书指纹，便于排查连接问题。

## 设备密钥

设备私钥别名为 `limlink-device-v2`，允许 `DIGEST_NONE`。旧的 v1 密钥缺少该授权，Conscrypt 在 TLS 握手中以 NONEwithECDSA 签名时 KeyStore 返回 `INCOMPATIBLE_DIGEST`，导致所有收发握手失败；启动时会删除 v1 并生成 v2，本机指纹因此变化一次。设备密钥变化会使旧绑定失效，需要重新绑定；仍可通过逐次确认传输文件。该握手问题在模拟器上与 Windows 客户端互通时发现并验证修复。

设置中可保存自定义设备名和接收目录。默认保存到 Downloads；指定目录失去授权时沿用现有策略改存 Downloads。远程链接和邀请码入口没有启用，生产流程没有模拟传输或人工指纹核对。

## 传输与存储

- 单个文件支持 `0..5,000,000,000` 字节，单块最多 `1,048,576` 字节，大小/偏移使用 `Long`。一次可以选择多个文件，每个文件使用独立的会话顺序发送；快照、接收、摘要和发布均按有界块处理。
- AndroidKeyStore 保存不可导出的 EC 设备私钥。TLS 1.3 双向证书，SPKI SHA-256/base64url 指纹自动绑定所选发现记录；不信任设备名称来替代连接身份。
- DNS-SD `_limlink._tcp`，TXT `pv=1.0`、`fp`、`dt=android`、`app=limlink`，过滤本机、无效指纹和不兼容 app。
- hello、sessions、poll、PUT、complete、finish 共用一条 TLS 连接。会话是连接私有的，最多四条接收连接，批准/普通请求空闲超时 120 秒；仅等待文件校验与保存发布的 complete 请求最多 30 分钟，仍可主动取消。
- HTTP 只接受有界 Content-Length；拒绝重复/冲突长度、传输编码、非精确整数、错误 token、偏移、会话和路径。
- 接收内容先进入私有 staging；长度和 SHA-256 匹配后才调用保存接口。MediaStore 使用 `IS_PENDING`；SAF 只接受 provider 重命名发布，拒绝重命名失败后的公开文件复制回退。重名不覆盖。
- 取消、断开、拒绝、摘要或保存失败清理 staging。应用重启回收私有 staging 与已记录的未发布目标。已完成公开文件不回收。
- 接收端本地取消会阻止尚未完成的发布。对端断开可能在当前校验/发布步骤结束后才被检测；已经原子发布的完整文件不会被随后检测到的取消或断开撤回。
- 不提供跨连接续传和暂停按钮。若连接断开，请重新选择并发送。

## 构建和检查

需要 JDK 21、Android SDK 36。Gradle Wrapper 自动下载固定版本；CN/WD 共用正式包名 `com.limlink`，在 `gradle.properties` 的 `limlink.applicationId` 修改。

```bash
cd android
./gradlew :app:assembleDebug check --no-daemon --max-workers=4
```

APK：`app/build/outputs/apk/debug/app-debug.apk`。`check` 执行单元测试、lint 和主 Kotlin 源码中文检查。产品文案在 Android 资源中。

JVM 回归测试覆盖批准前禁止写入、hello 名称、连接归属、token/偏移、精确数字、5 GB 元数据边界、HTTP 截断/长度、摘要失败/清理、空文件、块大小、ACK、重名、发布失败、发布中本地取消以及完成请求的独立超时。测试文件使用磁盘快照，测试不假定整文件放进内存。

测试目录还包含 `JvmInteropHost`，允许独立 TLS 协议探针对 portable core 做互操作验证。它使用显式 PKCS12 测试身份并自动同意，**不编入 APK**：

```bash
./gradlew :limlink-kit:interopHost \
  '-PinteropArgs=/tmp/test-identity.p12|/tmp/received|/tmp/listener.json' --no-daemon
```

测试 PKCS12 口令是 `limlink-test`，证书使用具名 P-256 曲线，监听地址只限 loopback；JSON 输出包含端口与 SPKI 指纹。

## 验证边界

2026-10-18 的最终源码已通过 debug APK 构建、41 项 kit JVM 测试、4 项 UI 基础测试，以及三个模块的 lintDebug 和资源文案检查。APK 签名校验通过；lint 没有错误，仍有未使用资源、依赖版本等警告。

2026-10-19 在本机 JDK 21 / Android SDK 36 上重新执行 `:app:assembleDebug check` 通过，并在 API 36 模拟器安装 0.5.3 调试包；同时选择两个小文件后，首页正确显示“2 files”、总大小 13 B 和两个文件名。模拟器未与第二台设备完成实际发送。

本次环境为 macOS 上的 JDK/Android SDK，可构建 APK 并运行 portable core JVM 测试。尚未在 Android 真机/模拟器执行 AndroidKeyStore、NSD、前台服务和 MediaStore/SAF 的运行时验收，也尚未实测 Android 设备传输 5 GB。JVM/Apple 的测试结果不能替代这些设备验收。SAF provider 是否支持安全重命名需要按实际保存位置验证；不支持时报告保存失败。

### Independent device binding

Settings → Bind a device works without selecting a file. Choosing Bind grants this
phone permission to receive future files from the selected TLS key; only the other
device sees Accept/Reject. Both devices must complete the same relationship before
file hello can enable automatic reception. Device names are display labels and
can be changed by their owners. This first-use choice does not verify ownership.

Binding control uses a dedicated pinned TLS connection, recipient confirmation,
a fixed 120 second deadline, connection-owned tokens, and the `binding-v1` wire
contract. File cancellation leaves unrelated binding connections alone. Unbind
clears local permission first and attempts exact-relationship revocation when the
peer is discoverable; offline peers may retain their own record. Already accepted
files keep the existing save/cancel behavior. Binding does not add background or
closed-app receiving.

Records are atomically replaced in `Context.noBackupFilesDir`, not Android backup,
and scoped to the AndroidKeyStore SPKI. Restoring app settings onto a new key,
corrupt records, storage failure, old clients, and missing or mismatched per-hello
binding IDs all keep per-file consent. AndroidKeyStore and live Compose behavior
still require on-device validation; JVM protocol tests do not claim that coverage.

2026-10-23：绑定版本的 `:app:assembleDebug check` 已通过。kit 在 debug、release
变体各执行 73 项测试（含绑定状态、解绑并发与控制 socket 总超时回归），UI 模块各执行 4 项测试，均无失败或跳过。
三个模块的 lint 均无错误，仍有 103 条非阻断警告；九种语言的绑定资源键和格式参数检查通过。
完成审查修复后重新执行全量检查与 `:app:assembleDebug` 通过；最新调试 APK 为
`com.limlink.dev`、版本 `0.6.0` / build `14`，APK v2 签名校验通过。
此记录仅证明构建、JVM 协议测试和静态检查；尚未验证 Android 真机绑定、自动接收和 5 GB 传输。

2026-10-23 界面对齐：移除发起绑定时的介绍文字，保留接收方首次绑定确认中的授权说明。
设置最底部提供可直接打开的离线隐私说明与“用户协议与使用说明”，后者覆盖现有九种语言，
明确 Android 支持多文件选择、每个文件最多 5,000,000,000 字节，以及绑定、解绑、保存和支持说明。
本页不套用 Apple 许可，也不依赖外部法律页面。`:app:assembleDebug check` 再次通过，
三个模块 lint 共 0 错误、104 条非阻断警告；已有 JVM 测试任务复用未变更的通过结果。
最新调试 APK 为 `com.limlink.dev`、版本 `0.6.0` / build `15`，APK v2 签名验证通过，
签名证书与 build `14` 相同。未进行 Android 真机或模拟器安装、页面导航及传输运行时验收。

2026-10-24 官网接入：两份离线文档末尾增加官网全文入口，运营公司与 `.com` 邮箱同步；九种界面语言继续保留，官网其他语言由用户适配。`:app:assembleDebug check --offline` 通过，最新 Mac 调试包为 0.6.0 build 16。尚未安装到三星；三星现有包使用 Windows 的另一签名身份，后续须保留原密钥重签后再覆盖更新。

2026-10-24 九语种后续更新：官网九语种共 18 页已发布核验，链接随 App 实际语言选择；离线说明收录第八节与新增第十节的原文摘录。`:app:assembleDebug check --offline` 通过，当前 Mac 调试包为 0.6.0 build 17，仍未安装到三星。
