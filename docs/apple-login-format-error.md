# Apple login format errors in xtool, AltServer, and SideStore

[English](#what-the-error-means) | [中文](#中文排障说明) | [SideloadManager](../README.en.md)

## What the error means

`Encountered unknown tag html on line 1` means a property-list parser received HTML. `Unexpected character '<'` during JSON decoding can also mean an HTML or XML response, but that character alone does not identify the response type. `NSCocoaErrorDomain 3840` and `The data is not in the correct format` are parsing errors, not proof of a wrong Apple ID or password.

Possible causes include an upstream HTTP error, an intermediary returning an HTML page, or unexpected connection reuse behavior. The error text alone does not distinguish them. A successful browser login does not verify the separate GrandSlam authentication flow.

## Check before changing accounts or reinstalling

1. Record the app version, macOS version, failing host/path, HTTP status, and content type when available. Avoid sharing passwords, codes, tokens, cookies, or raw authentication responses.
2. Distinguish a TLS failure (`NSURLErrorDomain -1200`) from an HTTP response that failed decoding. Disabling certificate validation is not a fix.
3. Check whether the affected process inherits a stale proxy and whether a system proxy or VPN is active. A different network can help isolate routing issues but is not a guaranteed solution.
4. Check current upstream issues before applying a workaround. Persistent Apple service failures can remain even with retries.

## An xtool-based option for macOS users

[SideloadManager](../README.en.md) provides a native macOS GUI for importing original IPA files, signing and installing through xtool, tracking profile expiration, and scheduling refreshes. This is a separate workflow, not a patch for AltStore or SideStore on the phone.

The repository includes an [auditable xtool 1.19.0 patch](../patches/xtool-1.19.0-grandslam-retry.patch) and [build script](../scripts/build-xtool.sh). The patch isolates GrandSlam requests, detects HTML/HTTP 5xx before decoding, and performs bounded retries at authentication transaction boundaries. It does not guarantee that every format error will be resolved, and does not fix every MID/anisette or TLS failure.

See the [source build instructions](../README.en.md#build-and-install-from-source). macOS 14+ is required; the complete build requires Xcode 26.3 / Swift 6.2 and XcodeGen. There is currently no prebuilt release download.

For refresh, retain the original IPA and keep the Mac awake with a reachable, trusted iPhone and a valid xtool login. Apple signing limits still apply. Migration from another signing tool may change app identity; do not delete an existing app without considering its data.

## Related public reports

- [xtool #232: login failed](https://github.com/xtool-org/xtool/issues/232): reports HTML being decoded as a property list.
- [AltStore #1781: AltServer cannot connect to Apple ID](https://github.com/altstoreio/AltStore/issues/1781): related format errors and discussion of desktop IPA signing.
- [AltStore #1782: format error and observed HTTP 503](https://github.com/altstoreio/AltStore/issues/1782): community diagnostics and proposed fixes. Reports and third-party builds are not independently verified by this document.

## 中文排障说明

Apple 登录提示“数据格式不正确”、`Encountered unknown tag html` 或 `NSCocoaErrorDomain 3840`，不等于账号或密码错误。HTML 标签错误说明解析器收到了网页；JSON 的 `<` 错误也可能来自 XML。应先确认失败接口、HTTP 状态码和响应类型，再判断是 Apple 服务、代理还是连接复用问题。

TLS 错误、`MID is invalid (-80009)` 和格式解析错误属于不同阶段，不应当套用同一个修复。不要关闭证书校验，也不要公开验证码、令牌或原始认证响应。

本项目提供的是基于修复版 xtool 的 Mac 自签工作流，可管理 IPA、到期计划和后台刷新。它不会修改手机上 AltStore/SideStore 的登录逻辑，也不保证解决所有 Apple 登录故障。请按[中文构建说明](../README.md)安装；当前仅提供源码，需要 macOS 14+，完整构建需要 Xcode 26.3 / Swift 6.2 和 XcodeGen。

七天续签仍需保留原始 IPA、Mac 保持唤醒、手机可连接、账号有效，且受 Apple 配额限制。更换签名工具前应考虑应用身份与数据保留，不能靠删除应用来修复登录格式错误。
