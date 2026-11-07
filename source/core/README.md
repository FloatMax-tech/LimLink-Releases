# LimLink 核心（M0）

邀请码握手的共用 Rust 核心：套件 `CPACE-RISTR255-SHA512`（`pakery-cpace` 0.6.0，草案 draft-irtf-cfrg-cpace-21）、密钥确认、会话票据，以及邀请码的次数和过期。网络、TLS、HTTP、DNS-SD 和文件读写都在各端，不在这里。核心不读时钟，调用方传入 `now_ms`（单调毫秒，包含休眠）。

Rust 类型按以后能加 UniFFI 来摆。这一版**没有**依赖 UniFFI。

## 目录（别的端的 CI 路径过滤依赖这份布局）

| 路径 | 内容 |
| --- | --- |
| `include/limlink_core.h` | 发布用 C ABI，前缀 `llc_`，规范 15.10.8。手写，注释跟规范一致。 |
| `include/limlink_core_testvectors.h` | 只给测试构建，前缀 `llct_`，规范 15.10.9。发布包不要带上它。 |
| `vectors/limlink-core-vectors-v1.json` | 测试向量。草案 B.3、SAS、文件哈希、带 rng 脚本的邀请握手。 |
| `vectors/ref_impl.py` | 独立的 Python 参照（libsodium，不用 pakery）。 |
| `limlink-core/` | 核心库。 |
| `limlink-core-testvectors/` | 测试库，只导出 `llct_*`。 |
| `SPEC-QUESTIONS.md` | 规范没写死时采用的读法。 |

`bindings/` 留给以后的 Swift / Kotlin。这一版不建这个目录。

没有用 cbindgen。生成器写不出规范头文件里的注释。CI 用 `scripts/check_exports.py` 核对：头文件里声明的函数，和 `nm` 看到的导出符号，必须一致。

## 各端怎么接

- **Windows，以及任何先不走 UniFFI 的端：** 链 `limlink_core`（staticlib 或 cdylib），包含 `include/limlink_core.h`。只链这一份。版本字符串里如果出现 `+testrng`，应用应当拒绝加载。
- **测试：** 链 `limlink_core_testvectors`，包含 `include/limlink_core_testvectors.h`。构造函数多一个 rng 脚本。不要和发布库链在同一个二进制里。
- **SAS（4.3）和文件哈希（5.5）不在 C ABI 里。** 各端按向量自己算。Rust 侧有 `compute_sas`、`sha256_hex`、`parse_sha256_hex`，给本仓库的测试用，也给以后的 UniFFI 用。不要把大文件从 FFI 送进来。

`llc_abi_version()` 现在是 1。错误码 1–14 对应 `CoreError`，100 空指针，101 长度不对，102 内部 panic 已被接住。

## Rust API（15.10.7）

发送方 `InviteSender`：`new(now_ms)`、`code()`、`status(now_ms)`、`accept_hello`、`respond_pake`（进入时就扣一次）、`verify_confirm`、`cancel_attempt`、`cancel`。

接收方 `InviteReceiver`：`new(code)`、`begin()`。`ReceiverAttempt`：`nonce_r`、`suites`、`start`、`finish`（先验 Tb，再返回 Ta）、`verify_ticket`（票据和客户端指纹一起比，接收方拿不到票据明文以外的比较中间值）。票据只能成功核销一次。已经核销后再拿同一张票据和同一个指纹来，核心返回 `TicketUsed`（14）；票据或指纹有一个对不上，返回 `TicketMismatch`。失败不核销。线上这两种错误都是 403 `E_INVITE_TICKET_INVALID`。`TicketUsed` 只给接收方判断要不要关掉自己的第一场会话（协议 15.5）。这次调用挂在 `ReceiverAttempt` 上，邀请已经 `succeeded`、或 30 秒确认窗口过了，都还能核销，不会变成 `BadState` / `UnknownAttempt`。attempt 释放之后核心不再管。

状态：`waiting` / `in_progress` / `succeeded` / `exhausted` / `expired` / `cancelled`。`attempts_left = 3 - 已扣次数`（进行中的那次已经扣了）。`failures` 只算已经结束的失败。对象内部有锁，没有回调，也没有自己的线程。

码只能由核心用操作系统 CSPRNG 生成（拒绝采样，均匀的 `000000`–`999999`）。过期 10 分钟，总共 3 次失败（不是按 IP），成功后码作废。

## 测试构建的四道闸（15.10.9）

1. `test-rng` 和 release 放在一起，`build.rs` 和 `compile_error!` 都会让编译失败。
2. CI 对发布库做 `nm`：没有 `llct_`，也没有 `limlink_core_testvectors` 这个名字。
3. 测试构建的版本字符串带 `+testrng`。
4. 发布应用只链 `limlink_core`。

脚本顺序和核心的抽法相同：发送方先是 4 字节的码（拒绝采样照样做），每次 `accept_hello` 再抽 16 字节 nonceS 和 16 字节会话 id，每次 `respond_pake` 抽 64 字节 CPace 标量；接收方 `begin` 抽 16 字节 nonceR，`start` 抽 64 字节标量。脚本抽干返回 `Rng`。

## 向量

```bash
# 在 core/ 下。Python 参照需要系统的 libsodium（libsodium.so.23）。
python3 vectors/ref_impl.py --check
cargo test -p limlink-core
cargo test -p limlink-core --features test-rng
cargo test -p limlink-core-testvectors
```

`--check` 用 libsodium 重算 JSON，和磁盘上的文件逐项比较。Rust 测试再跟同一份 JSON 对拍，包括 SAS **672029**、草案附录 B.3，以及 `stateMachine` 里用显式 `nowMs` 重放的过期、三次失败、Busy、取消和 30 秒确认超时。`fileHash` 里的 `one-mib-pattern` 不存原文，按 `generator` 逐块更新 SHA-256。`--write` 会重写 JSON，只在参照实现改了的时候用。

`cargo test --workspace` 会因为特性合并把 `test-rng` 打开，所以 CI 把两个包分开测。不要在 workspace 上跑 `cargo test --release`。

## 发布包

工作流 `core-release`（`.github/workflows/core-release.yml`）只在手动运行，或者推送 `core-v*` tag 时跑。日常的 pull request 不会跑它。Apple 那一步也只在这两种情况下跑。产物进一个 **draft** GitHub Release，根上有 `SHA256SUMS`。

测试包是 **dev profile**。`test-rng` 和 release profile 放在一起会直接编译失败，所以测试用的 `.so` / `.dll` 不是 `--release`。里面同时有 `llc_*`（操作系统随机数）和 `llct_*`（脚本随机数），这是 Cargo feature `bundled-llc`。仓库里默认的 `limlink-core-testvectors` 构建仍然只有 `llct_*`，那道泄漏检查不动。两份库的对象不能混着传。

### Android

NDK r28c，`minSdk 29`，ABI `arm64-v8a` 和 `x86_64`。链接时带 `-Wl,-z,max-page-size=16384`。每个 LOAD 段的 Align 至少是 `0x4000`。

| 压缩包 | 库 | 头文件 |
| --- | --- | --- |
| `limlink-android-<abi>.zip` | `jni/<abi>/liblimlink_core.so`，只导出 `llc_*` | `include/limlink_core.h` |
| `limlink-android-<abi>-test.zip` | `jni/<abi>/liblimlink_core_testvectors.so`，`llc_*` 和 `llct_*` | 两份头文件 |

放到 `app/src/main/jniLibs/<abi>/`，`System.loadLibrary("limlink_core")`。测试包单独加载，不要和正式 so 同时把对象传来传去。

### Windows

在 Ubuntu 上用 cargo-xwin 出 MSVC DLL（`x86_64` 和 `aarch64`）。压缩包里是 `limlink_core.dll`、导入库 `limlink_core.dll.lib`、`limlink_core.pdb`，加上 `include/limlink_core.h`。测试包的文件名是 `limlink_core_testvectors.dll`（以及对应的 `.dll.lib` 和 `.pdb`），两份头文件都在。正式 DLL 的导出只有 `llc_*`。P/Invoke 加载 DLL，链接时用那份导入库。

### Apple

只有发布构建，静态 `LimLinkCoreFFI.xcframework`。切片是 `ios-arm64`、`ios-arm64_x86_64-simulator`、`macos-arm64_x86_64`。`IPHONEOS_DEPLOYMENT_TARGET=17.0`，`MACOSX_DEPLOYMENT_TARGET=14.0`。每个切片的头文件和 `module.modulemap` 在 `Headers/LimLinkCoreFFI/` 里，不在 `Headers/` 根目录，避免和别的静态 XCFramework 一起嵌进同一个 App 时抢顶层的 `module.modulemap`。模块名仍是 `LimLinkCoreFFI`。modulemap 里的头文件路径相对这个子目录，写成 `header "limlink_core.h"`。`nm` 里没有 `llct_`。旁边的 `LimLinkCoreFFI.xcframework.checksum.txt` 是 `swift package compute-checksum` 的结果，给 SwiftPM 二进制目标用。Xcode 里把 xcframework 拖进工程，`import LimLinkCoreFFI`。

## 构建

工具链用 stable（`pakery-cpace` 0.6.0 要求 Rust 1.85+）。本仓库不放 `rust-toolchain.toml`。

```bash
cargo build -p limlink-core
cargo build --release -p limlink-core
```

Apple / Windows 目标在 Linux 上只做 `cargo check --target`，不链接：`aarch64-linux-android`、`x86_64-pc-windows-gnu`、`x86_64-pc-windows-msvc`、`aarch64-pc-windows-msvc`、`aarch64-apple-ios`、`aarch64-apple-darwin`。CI 没有 macOS 或 Windows runner。工作流只在 `core/**` 和这个工作流文件变化时、对 pull request 和 `main` 的 push 触发。
