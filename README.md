<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="SideloadManager icon">
</p>

# SideloadManager：iPhone IPA 自签与自动刷新管理器（macOS）

[简体中文](README.md) | [English](README.en.md)

[![Build](https://github.com/Zhang161215/SideloadManager/actions/workflows/build.yml/badge.svg)](https://github.com/Zhang161215/SideloadManager/actions/workflows/build.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000)](https://www.apple.com/macos/)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![MIT License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**SideloadManager 是一个开源、原生的 macOS iPhone IPA 自签管理器。** 它以 [`xtool`](https://github.com/xtool-org/xtool) 为签名与安装后端，提供图形界面来管理 IPA、已连接 iPhone、Apple Developer provisioning profile 到期时间、手动重新签名以及后台定时刷新。

> **English:** SideloadManager is an open-source native macOS GUI for sideloading IPA files to an iPhone with xtool, monitoring Apple development provisioning profiles, and scheduling app re-signing before expiration.

仓库还提供一份可审计的 `xtool 1.19.0` Apple GrandSlam 兼容补丁。它通过隔离 GrandSlam 会话降低异常连接复用的影响，并在 `gsa.apple.com/grandslam/GsService2/lookup` 返回 HTML 或 HTTP 5xx 时，在安全的认证事务边界执行有限重试。这些响应原本可能被误报为 `The data is not in the correct format`、`Unexpected character '<'` 或 `Encountered unknown tag html`。

> 这是非官方工具，与 Apple、xtool、AltStore、AltServer 和 SideStore 的维护者均无隶属关系。相关名称归各自权利人所有。它不会绕过 Apple 的账号验证、设备限制或开发者计划规则。

## SideloadManager 项目概览

| 项目 | 说明 |
| --- | --- |
| 类型 | 开源、原生 SwiftUI macOS 桌面应用 |
| 运行环境 | macOS 14+；完整构建使用 Xcode 26.3 / Swift 6.2 |
| 目标设备 | 已信任的 iPhone，支持 USB 或可用的网络配对 |
| 核心用途 | IPA 导入、签名安装、重新签名、到期跟踪、后台定时刷新 |
| 底层工具 | xtool 1.19.0、Xcode `devicectl` |
| 开发者账号 | 用户自己的 Apple ID；免费账号可用，但 Apple 限制仍然生效 |
| 发布形式 | 当前提供源码、构建脚本和可审计补丁，不提供预编译 Release 下载 |
| 许可证 | MIT |

## SideloadManager 解决什么问题

- 希望在 Mac 上用图形界面导入、签名、安装和刷新 iPhone IPA，而不是反复输入 xtool 命令。
- 使用免费 Apple Developer profile，需要掌握通常为 7 天的签名周期，并在到期前重新签名。
- Apple GrandSlam 登录接口返回 HTML 或 5xx，导致 xtool 把响应误报成 plist/JSON 格式错误。
- 只想管理通过开发者签名安装的应用，不希望系统应用和 App Store 应用混入列表。
- 需要在 Mac 后台定时检查签名、失败重试，并在 iPhone 已连接且满足安装条件时刷新应用。

本项目不是永久签名服务，也不是 Apple 限制绕过工具。自动刷新仍要求 Mac 正在运行、iPhone 可被 Xcode 识别、设备已信任此 Mac，并且账号、网络和签名配额状态正常。

## SideloadManager 主要功能

- 自动识别 USB 和网络连接的 iPhone，并按 UDID 去重；当前安装和管理操作使用第一台可用设备
- 显示设备名称、型号、系统版本、连接方式和锁定状态
- 导入并本地归档 IPA，提取应用名称、Bundle ID 和图标
- 只读取 developer apps（通常包括自签/开发签名应用），不混入系统应用和普通 App Store 应用
- 一键签名安装、刷新和卸载，并提供明确的运行中/成功/失败反馈
- 按原始/XTL Bundle ID 匹配账号侧 `ACTIVE + IOS_APP_DEVELOPMENT` 中最晚到期的 provisioning profile
- 到期提醒、搜索、状态筛选和刷新计划图表
- launchd 每小时唤醒检查计划，按设定间隔刷新，失败后自动重试并发送 macOS 通知
- 后台刷新、登录自启和插入 USB iPhone 时自动打开均为可选功能，默认全部关闭
- 从 xtool 和 `devicectl` 子进程中移除常见代理环境变量，避免继承失效的终端代理；不会修改 macOS 系统代理、VPN 或证书

## 当前支持范围与限制

- 可以检测并去重多台 iPhone，但当前没有设备选择器；安装、卸载、手机应用读取和后台刷新使用第一台可用设备。
- 到期时间来自账号侧 development provisioning profiles，不是直接读取手机内 embedded profile；匹配不到时使用预计时间。
- 后台任务每小时检查一次计划，不是精确时刻调度，也不会唤醒睡眠中的 Mac。
- 刷新必须保留原始 IPA，并要求 xtool 登录有效、Mac 醒着且 iPhone 可达；设备离线时无法凭空完成续签。
- 不绕过 Apple 的两步验证、证书吊销、免费账号 7 天期限、应用数量或 App ID 限制。

## 与 xtool、AltStore、AltServer 和 SideStore 的关系

| 组件 | 在本项目中的作用 |
| --- | --- |
| **SideloadManager** | 本仓库提供的 SwiftUI 图形管理器，负责 IPA 归档、设备状态、到期计划、日志和后台任务。 |
| **xtool** | 实际执行 Apple ID 认证、开发者签名和 IPA 安装的后端；SideloadManager 不重新实现其签名协议。 |
| **xtool-fixed** | 由本仓库脚本从固定的 xtool 1.19.0 上游提交构建，并应用可审计的 GrandSlam 重试补丁。 |
| **Xcode `devicectl`** | 读取 iPhone 型号、连接状态、开发者应用和图标，并执行卸载等设备操作。 |
| **AltStore / AltServer / SideStore** | 独立项目，不是 SideloadManager 的依赖。本仓库不会修改其登录实现，也不兼容它们的刷新协议。 |

如果 AltServer 或 SideStore 报出相似的 Apple 登录格式错误，本项目提供的是一条基于 xtool 的独立自签工作流；GrandSlam 补丁只应用于本仓库构建的 `xtool-fixed`。要重新签名由其他工具安装的应用，仍需取得并导入原始 IPA。

## SideloadManager 如何工作

```text
SideloadManager
  ├─ 管理 IPA、计划、日志和本地状态
  ├─ 调用 xtool 完成 Apple 登录、签名和安装
  └─ 调用 Xcode devicectl 读取设备和 developer apps
```

登录由本机运行的 `xtool` 与 Apple 服务交互；SideloadManager 不接收明文密码，成功登录后的令牌由 macOS 版 xtool 存入 Keychain 服务 `sh.xtool.keychain.credentials`。仓库不包含 Apple ID、密码、验证码、登录令牌、Team ID、设备 UDID、IPA、预签名 profile 或个人配置。

## macOS 与 iPhone 环境要求

- macOS 14 或更高版本
- Xcode 26.3 和 Xcode Command Line Tools，或其他支持 Swift 6.2 的更新版本
- SideloadManager 本体使用 Swift tools 6.0；包含修复版 xtool 的完整构建需要 Swift 6.2
- `git`、可访问 GitHub 的网络，以及可用的 `xcrun devicectl`
- 受信任并已解锁的 iPhone；设备系统版本必须受当前 Xcode 支持
- 用户自己的 Apple ID；免费开发者账号也可以使用
- 构建修复版 `xtool.app` 时需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 从源码构建并安装 SideloadManager

目前仓库只提供源码构建，不提供预编译的 GitHub Release。构建过程会从 xtool 官方仓库检出固定提交、校验补丁、在本机编译并进行临时签名。

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

安装完成后，先在终端登录一次 Apple ID。命令中的 Apple ID 用户名可能保留在 shell history；密码和双重验证码会交互式读取，不会写进命令历史：

```bash
~/Applications/xtool-fixed.app/Contents/Resources/bin/xtool \
  auth login --mode password --username '你的 Apple ID'
```

然后打开 `~/Applications/SideloadManager.app`，在“应用管理”中导入 IPA。也可以把已有 `xtool` 可执行文件或 `.app` 路径放入 `SIDELOAD_XTOOL_PATH`；管理器还会自动检查常见安装位置和 `PATH`。

## xtool Apple GrandSlam 登录兼容补丁

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

## Apple 免费开发者账号的 7 天和应用数量限制

Apple 免费开发者 profile 通常只有 7 天有效期，并限制同一设备上可用的自签应用和 App ID 数量（常见上限为 3 个应用，实际规则由 Apple 决定并可能变化）。出现下面的提示时，需要先删除或停用已有自签应用，再重新安装：

```text
This device has reached the maximum number of installed apps using a free developer profile
```

这些限制由 Apple 服务和 iOS 强制执行，本工具不能解除。关闭 iOS 的“卸载未使用的 App”，并清理已经卸载但仍占用名额的应用，有助于避免错误计数。

## Apple 登录与签名故障排查

### `The data is not in the correct format`、`Unexpected character '<'` 或 `unknown tag html`

当下面几类信息出现在 xtool GrandSlam 登录阶段时，通常指向同一个问题：调用方期待 Apple 返回 plist 或 JSON，但实际响应以 `<html>` 开头。

```text
The data couldn't be read because it isn't in the correct format.
Encountered unknown tag html on line 1
Unexpected character '<' around line 1, column 1
Malformed data byte group at line 1; invalid hex
```

常见原因包括 Apple 网关临时异常、代理/VPN 返回的拦截页、TLS 中间人或地区网络出口。先确认系统代理、VPN、抓包证书和网络出口，再使用本仓库构建的 `xtool-fixed`。补丁会隔离 GrandSlam 连接，并仅在安全的认证事务边界重试 HTML/5xx 临时响应；它不会重试普通网络传输错误，不能修复永久封锁、账号状态异常或持续的 TLS 拦截，也不会改变 AltServer 自身的实现。

### `A TLS error caused the secure connection to fail` 或 `Failed to perform authentication handshake`

检查系统时间、代理/VPN、用户安装的根证书和网络出口。管理器会移除进程环境中的代理变量，但不会擅自修改 macOS 系统代理。

### `MID is invalid (-80009)`

注销并重置 xtool 的双重验证设备数据后重新登录。频繁切换网络或反复登录可能触发 Apple 风控，请避免短时间内连续尝试。

### 是否需要安装 AltServer、AltStore 或 SideStore

不需要。SideloadManager 直接调用 xtool 完成登录、签名和安装，使用 Xcode `devicectl` 管理设备。它可以与其他自签工具共存，但所有工具仍共享 Apple 对免费账号和设备施加的限制。

### 能否完全自动续签，不再连接手机

不能保证。launchd 每小时唤醒一次，再根据设置的检查间隔和下次运行时间决定是否刷新；它不会唤醒睡眠中的 Mac。执行时还需要 xtool 登录有效、原始 IPA 仍在本地归档、iPhone 通过 USB 或可用的网络配对被识别，并满足解锁、信任、Developer Mode、账号和配额等条件。

### 为什么只显示手机上的部分应用

这是预期行为。SideloadManager 使用 `devicectl --no-include-default-apps` 读取 developer apps（通常包括自签/开发签名应用）；系统应用和普通 App Store 应用不会出现在“手机应用”视图中，也不会因此自动加入 IPA 托管列表。

### 手机上的旧应用如何刷新

重新签名需要原始 IPA。先把对应 IPA 导入管理器，再点击刷新；仅从手机读取到应用名称并不能还原原始安装包。

### Profile 到期时间是否等于手机内签名到期时间

不一定。管理器按 Bundle ID 从当前账号的开发者 profiles 中选择最晚到期的一份，用于制定刷新计划；`devicectl` 不提供已安装应用 embedded profile 的完整内容。同一 Bundle ID 存在多份 profile 时，界面显示的是账号侧最佳匹配，并会明确标记为“Profile 到期”。

## SideloadManager 本地数据与隐私

SideloadManager 的配置、IPA 归档、图标和后台日志位于：

```text
~/Library/Application Support/SideloadManager/
```

xtool 在 macOS 上将成功登录后的令牌存入 Keychain 服务 `sh.xtool.keychain.credentials`；这些认证数据不属于本仓库。提交 issue 前请删除日志中的 Apple ID、Team ID、UDID、令牌和本地路径。

## 开发 SideloadManager

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
