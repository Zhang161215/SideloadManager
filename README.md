<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="SideloadManager icon">
</p>

# SideloadManager

一个原生 macOS 自签应用管理器。它以 `xtool` 为底层，集中管理 IPA、iPhone 连接、签名有效期、手动刷新和后台定时刷新。

本项目同时提供一份可审计的 `xtool 1.19.0` 兼容补丁，用来缓解 Apple GrandSlam 偶发返回 HTML/5xx、连接复用异常时出现的 `The data is not in the correct format` 等误导性解析错误。

> 这是非官方工具，与 Apple 和 xtool 项目均无隶属关系。它不会绕过 Apple 的账号验证、设备限制或开发者计划规则。

## 功能

- 自动识别 USB 和网络连接的 iPhone，并按 UDID 去重
- 显示设备名称、型号、系统版本、连接方式和锁定状态
- 导入并本地归档 IPA，提取应用名称、Bundle ID 和图标
- 只展示开发者/自签应用，不混入系统应用和 App Store 应用
- 一键签名安装、刷新和卸载，并提供明确的运行中/成功/失败反馈
- 按 Bundle ID 匹配账号中最新到期的 provisioning profile
- 到期提醒、搜索、状态筛选和刷新计划图表
- 后台定时刷新、失败自动重试和 macOS 通知
- 可选登录自启，以及插入 USB iPhone 时自动打开（默认均关闭）
- 自动清除传给 Apple 请求的代理环境变量，避免继承失效的终端代理

## 工作方式

```text
SideloadManager
  ├─ 管理 IPA、计划、日志和本地状态
  ├─ 调用 xtool 完成 Apple 登录、签名和安装
  └─ 调用 Xcode devicectl 读取设备、应用和签名信息
```

所有 Apple 凭据都由 `xtool` 在本机处理。仓库不包含 Apple ID、密码、验证码、登录令牌、Team ID、设备 UDID、IPA、预签名 profile 或个人配置。

## 环境要求

- macOS 14 或更高版本
- Xcode 和 Xcode Command Line Tools
- Swift 6
- 受信任并已解锁的 iPhone
- 用户自己的 Apple ID；免费开发者账号也可以使用
- 构建修复版 `xtool.app` 时需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 快速开始

```bash
git clone https://github.com/Zhang161215/SideloadManager.git
cd SideloadManager

# 1. 从固定的上游版本构建 GrandSlam 修复版 xtool.app
./scripts/build-xtool.sh

# 2. 构建 SideloadManager.app
./scripts/build-app.sh

# 3. 安装到当前用户的 Applications 目录
./scripts/install.sh
```

安装完成后，先在终端登录一次 Apple ID。密码和双重验证码会交互式读取，不会写进命令历史：

```bash
~/Applications/xtool-fixed.app/Contents/Resources/bin/xtool \
  auth login --mode password --username '你的 Apple ID'
```

然后打开 `~/Applications/SideloadManager.app`，在“应用管理”中导入 IPA。也可以把已有 `xtool` 可执行文件或 `.app` 路径放入 `SIDELOAD_XTOOL_PATH`；管理器还会自动检查常见安装位置和 `PATH`。

## GrandSlam 补丁

补丁基于 xtool `1.19.0` 的固定提交：

```text
893cf4f8f916673922a47bb94601ead6efc7669f
```

变更范围保持在 GrandSlam 网络兼容层：

1. macOS 上仅为 GrandSlam 请求创建一次性 ephemeral `URLSession`，读取完整响应后立即释放，不影响其他 xtool 网络请求和 WebSocket。
2. 识别 `text/html`、XHTML、带 BOM 或 XML 声明的 HTML，以及 HTTP 5xx 临时响应；正常 XML plist 不会被误判。
3. endpoint lookup 按单次 GET 重试；主认证按完整 SRP 事务重试；App Token 按完整取令牌请求重试。短信发送和验证码提交不会被自动重放。
4. 最多尝试 5 次，等待时间依次为 1、2、4、8 秒；耗尽次数后返回明确的 GrandSlam 临时响应错误。
5. 补丁附带响应识别测试，并由 CI 在固定上游提交上实际应用和编译测试。

源码补丁位于 [`patches/xtool-1.19.0-grandslam-retry.patch`](patches/xtool-1.19.0-grandslam-retry.patch)，构建脚本会校验固定提交后再应用它。仓库不直接提交修改后的黑盒二进制，也不提交任何 embedded provisioning profile。

## 免费账号限制

Apple 免费开发者 profile 通常只有 7 天有效期，并限制同一设备上可用的自签应用和 App ID 数量。出现下面的提示时，需要先删除或停用已有自签应用，再重新安装：

```text
This device has reached the maximum number of installed apps using a free developer profile
```

这些限制由 Apple 服务和 iOS 强制执行，本工具不能解除。关闭 iOS 的“卸载未使用的 App”，并清理已经卸载但仍占用名额的应用，有助于避免错误计数。

## 常见问题

### `The data is not in the correct format`

通常表示 Apple 接口返回了 HTML 网关页或其他非预期内容，而调用方仍按 plist/JSON 解析。先确认系统代理、VPN、抓包证书和网络出口，再使用本仓库的修复版。补丁会隔离 GrandSlam 连接并在安全的事务边界重试，但不能修复永久封锁、账号状态异常或持续的中间人 TLS 拦截。

### `A TLS error caused the secure connection to fail`

检查系统时间、代理/VPN、用户安装的根证书和网络出口。管理器会移除进程环境中的代理变量，但不会擅自修改 macOS 系统代理。

### `MID is invalid (-80009)`

注销并重置 xtool 的双重验证设备数据后重新登录。频繁切换网络或反复登录可能触发 Apple 风控，请避免短时间内连续尝试。

### 手机上的旧应用如何刷新

重新签名需要原始 IPA。先把对应 IPA 导入管理器，再点击刷新；仅从手机读取到应用名称并不能还原原始安装包。

### Profile 到期时间是否等于手机内签名到期时间

不一定。管理器按 Bundle ID 从当前账号的开发者 profiles 中选择最晚到期的一份，用于制定刷新计划；`devicectl` 不提供已安装应用 embedded profile 的完整内容。同一 Bundle ID 存在多份 profile 时，界面显示的是账号侧最佳匹配，并会明确标记为“Profile 到期”。

## 本地数据

SideloadManager 的配置、IPA 归档、图标和后台日志位于：

```text
~/Library/Application Support/SideloadManager/
```

xtool 的认证数据由其自身的 Keychain/本地存储实现管理，不属于本仓库。提交 issue 前请删除日志中的 Apple ID、Team ID、UDID、令牌和本地路径。

## 开发

```bash
swift build
swift run SideloadManager
```

直接 `swift run` 适合开发调试；登录自启、USB 自动打开和完整图标需要使用 `scripts/build-app.sh` 生成的 `.app`。

项目结构：

```text
Sources/SideloadManager/   SwiftUI 应用源码
Resources/                 Info.plist 和应用图标
patches/                   可审计的 xtool 补丁
scripts/                   构建与安装脚本
```

## 安全与免责声明

密码登录依赖 Apple 的非公开接口，接口可能随时变化。请只为自己拥有或获准测试的账号、设备和应用使用本工具。建议先阅读补丁并自行构建；使用产生的账号限制、证书吊销、数据丢失或其他风险由使用者承担。

## 许可证

SideloadManager 使用 [MIT License](LICENSE)。`xtool` 由 Kabir Oberai 及其贡献者开发并使用 MIT License；详细归属见 [NOTICE](NOTICE)。
