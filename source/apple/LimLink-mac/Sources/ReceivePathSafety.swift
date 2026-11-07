import Foundation

/// 协议 5.6 的路径安全和重名改名。
///
/// Mac 方案 1.2 把「文件名安全」放在共用的 LimLinkKit 里：拒绝绝对路径、`..` 和越界路径，
/// 单个文件重名加 ` (1)`，顶层文件夹重名时整棵改名、不合并。
/// Mac 能检出同名顶层文件夹，不用协议给安卓的「查不到则合并」例外。
///
/// 接收落盘通过共享 TransferFileStore 使用 LimLinkKit 的路径与重名规则。
enum ReceivePathSafety {
    static let owner = "LimLinkKit"
}
