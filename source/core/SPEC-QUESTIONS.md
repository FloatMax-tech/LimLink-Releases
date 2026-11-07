# 规范里曾经没写死、核心按保守读法做的地方

这些读法现在写进协议 **15.10.10**。实现和 `vectors/limlink-core-vectors-v1.json` 跟这一节对齐。票据一次性使用是 **15.5 / 15.10.7**，不再是开放问题。

## 密码学

- **CPace 临时标量。** `pakery-cpace` 0.6.0 抽 64 字节，再用 `Scalar::from_bytes_mod_order_wide` 对 ristretto255 的阶取模。草案 8.3 推荐的是 32 字节再清掉高 4 位（草案也允许在 `1 .. order-1` 上均匀抽样）。LimLink 跟 pakery：测试脚本里每次 `respond_pake` / `start` 消耗 **64** 字节。附录 B.3 的 32 字节标量，后面补 32 个 0，wide reduction 是恒等，才能对上草案的 Ya/Yb。这件事写在向量文件的 `cpaceDraftB3.note` 里。
- **密钥确认用 HMAC-SHA512**，不是 CMAC。`mac_key = SHA-512("CPaceMac" || sid || ISK)`，`Ta`/`Tb` = HMAC-SHA512(mac_key, lv_cat(点, AD))，各 64 字节。
- **票据。** HKDF-SHA512，salt = sid（32 字节），IKM = ISK（64 字节），info = ASCII `limlink invite v1 ticket`（没有结尾 NUL），输出取前 32 字节。ISK 不进 C ABI，也不出现在 `ConfirmResult` 以外的返回值里；调用方只拿到票据和对方指纹。**一次性（15.5 / 15.10.7）：** 第一次 `verify_ticket` 成功后核心把票据标成已消费。失败的校验不消费。已经消费之后，票据和 `fp_client` 都与第一次成功时相同（两次比较都是常量时间）返回 `TicketUsed`（C 码 14）；否则返回 `TicketMismatch`。线上两者都映射成 403 `E_INVITE_TICKET_INVALID`。`TicketUsed` 只给接收方用来决定要不要关掉自己的第一场会话。核销挂在 `ReceiverAttempt` 上：邀请已经是 `succeeded`，或者 30 秒确认窗口已经过去，都不改变这次调用，不会因此返回 `BadState` / `UnknownAttempt`。平台把 attempt 留到第一场会话结束；`llc_attempt_free` 之后核心不再提供这次核销。
- **CI。** `lv_cat("limlink-invite-v1", fp_receiver, fp_sender)`，指纹是原始 32 字节 SPKI SHA-256。发送方 `respond_pake(fp_self=发送方, fp_peer=接收方)`，接收方 `start(fp_self=接收方, fp_peer=发送方)`，两边拼出来的 CI 相同。
- **sid。** `nonceR || nonceS`，各 16 字节。接收方是 CPace initiator（发 Ya），发送方是 responder（发 Yb）。模式固定 `InitiatorResponder`。
- **ADa / ADb。** `lv_cat("limlink/1", "recv", 套件列表)` 和 `lv_cat("limlink/1", "send", 选中的套件)`。第三段是逗号连接的 ASCII，没有空格。接收方永远只广告 `CPACE-RISTR255-SHA512`。发送方必须在对方列表里看到这一项，否则 `SuiteUnsupported`。多出来的、符合 token 语法的名字按原顺序留在 ADa 里，不拿来当选中套件。token：非空、不超过 63 字节、字符集 `[A-Za-z0-9._+-]`。网上来的 `peer_suites` 是一整段逗号分隔文本：**先看总字节数，超过 255 直接 `SuiteUnsupported`，不再切开。** 空段、空格、非 ASCII、非法 token 也是 `SuiteUnsupported`。
- **SAS 和文件哈希不在冻结的 C ABI 里。** 15.10.9 让各端自己算。核心仍提供 Rust 函数 `compute_sas`、`sha256_hex`、`parse_sha256_hex`，向量也在同一份 JSON 里，方便对拍。核心不读文件、不把大文件送过 FFI。`parse_sha256_hex` 接受大小写混合的 64 个十六进制字符。

## 邀请码状态机

- **抽码。** 4 字节按大端读成 `u32`（和 SAS 的大端一致）。`LIMIT = 2^32 - (2^32 % 10^6) = 4294000000`。`v < LIMIT` 才接受，码 = `v % 1000000`，格式 `%06d`。否则丢掉重抽。连续 1024 次仍被丢掉，返回 `Rng`。规范里提到的 `2^32 % 10^6 = 967296` 就是这份偏差，拒绝采样把它消掉。
- **什么时候扣次。** `respond_pake` 确认会话 id 存在、不是 Busy、也不是终态之后，立刻 `deducted += 1` 并拿走 hello 槽。长度不对、点编码非法、或是恒等元：这次算一次已经结束的失败，不发出 Yb，返回 `InvalidPeerMessage`。第三次这样的失败进入 `exhausted`。
- **Yb 还没离开核心时 RNG 失败。** 扣次回滚，hello 放回原来的位置，返回 `Rng`。三次上限是为了不让攻击者拿 Yb/Tb 去试口令；没有消息离开核心，回滚不会把上限放宽。
- **30 秒确认超时。** 从 `respond_pake` 拿到的 `now_ms` 起，`now - started >= 30000` 算超时。下一次带 `now_ms` 的调用（包括 `status` 和 `verify_confirm`）先把这次尝试收成失败。`verify_confirm` 在这之后：若这是第三次失败返回 `Exhausted`，否则返回 `UnknownAttempt`。迟到的正确 Ta 不接受。
- **10 分钟过期。** `now.saturating_sub(created) >= 600000`。`now < created` 不过期。已经是终态就不再改成过期。过期时不给进行中的那次额外加 `failures`，计数保持原样，码清掉。所有终态的 `expires_in_ms` 都是 0。
- **`cancel_attempt` / `cancel` 不带 `now_ms`。** 它们不推进过期，也不推进 30 秒计时器。取消一个还在进行的 pake：算一次已结束的失败，扣次保留。取消一个还没进入 pake 的 hello：丢掉槽位，不算失败。`cancel()` 在已经是 `cancelled` 时返回成功；在 `succeeded` / `exhausted` / `expired` 时返回 `NotActive`。
- **`accept_hello` 在 `in_progress` 时仍然允许。** 槽位和当前这一次 pake 是分开的。已经有一次 pake 在进行时，再对另一个 hello 调用 `respond_pake` 返回 `Busy`，不扣次。
- **最多 8 个还没开始的 hello。** 第 9 个进来时丢掉最旧的那个。
- **终态粘住。** `succeeded`、`exhausted`、`expired`、`cancelled` 之后不再回到等待。成功不是失败：`failures` 不变，成功的那次算在 `deducted` 里，`attempts_left = 3 - deducted`，码清掉。
- **`code()` 没有 `now_ms`。** 它自己不会把对象过期。等待和进行中返回 6 位数字；终态返回空串。
- **码的格式。** 必须正好 6 个 ASCII 数字。全角数字和空格由调用方先转好；核心不转，直接 `CodeFormat`。
- **`inviteSessionId`。** 16 字节 CSPRNG，base64url、无 padding，正好 22 个字符。比较的是我们发出去的那串原文。字母表是 `A-Za-z0-9-_`。

## C ABI

- **头文件手写**，放在 `include/`，正文跟规范 15.10.8 / 15.10.9 一致。没有用 cbindgen：生成器写不出规范里那些注释，而别的端的 CI 依赖这份布局。CI 用 `nm` 核对「头文件里声明的函数」和「库里导出的符号」，而不是再生成一份头文件来 diff。
- **必填指针是空的：** 返回 `NULL_ARG`（100），不写输出。长度在动笔之前就不对：返回 `BUFFER_LEN`（101），不写输出。长度已经合法之后的业务错误：文本输出写成空 C 字符串，二进制输出清零；该置空的对象指针写成 NULL。
- **会话 id 长度不是 22：** C 层 `BUFFER_LEN`。22 字节但不是 UTF-8：`UnknownAttempt`。
- **测试脚本最长 65536 字节**，更长是 `BUFFER_LEN`。长度为 0 时指针可以是空的，对象能建出来，但一抽字节就 `Rng`（抽码发生在 `sender_new` 里，所以空脚本的发送方构造直接失败）。
- **脚本只传给 `llct_sender_new` 和 `llct_receiver_new`。** 规范 15.10.9 写「等」没有把每个函数都列完。读法是：脚本存在对象上，按调用顺序消耗。接收方 `begin` 抽 16 字节 nonceR，`start` 抽 64 字节标量；发送方构造时抽码，`accept_hello` 先抽 nonceS 再抽 16 字节会话 id，`respond_pake` 抽 64 字节标量。attempt 不再单独带脚本参数。
- **`free(NULL)` 什么都不做。** 对同一指针 `free` 两次是未定义行为（规范已经这样写）。attempt 持有 receiver 的 `Arc`，两边谁先释放都可以。
- **每个 `extern "C"` 导出的整个函数体都在 `catch_unwind` 里**，包括 `read_text`、`from_utf8` 和切片构造。panic 变成 `PANIC`（102）；已经有对象时把它标成毒化，之后的调用返回 `BadState`。这依赖 `panic = "unwind"`（`dev` 和 `release` 都写明了）。`panic = "abort"` 会让这个错误码失效。
- **`llc_invite_status` 24 字节、无填充。** `reserved` 写 0。

## 明确没做的

- 没有加 UniFFI。Rust 类型按以后能套 UniFFI 来摆，但依赖要等法务。Swift / Kotlin 的绑定目录 `core/bindings/` 现在不建。
- 没有网络、TLS、HTTP、DNS-SD、文件 IO、日志，核心也不读时钟。
