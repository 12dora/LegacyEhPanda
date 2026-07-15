# LegacyEhPanda

**English** · [简体中文](#legacypanda-简体中文)

An **iOS 16–compatible** fork of [EhPanda](https://github.com/EhPanda-Team/EhPanda), based on the last upstream release that still supports iOS 16 (**v2.7.5**), with important **business / site-compatibility fixes** backported from newer EhPanda versions.

> This project is **not** affiliated with the EhPanda Team or E-Hentai.  
> It exists so devices stuck on **iOS 16** can keep using EhPanda with up-to-date parsing and settings fixes.

---

## Why this fork?

| | Upstream EhPanda (recent) | **LegacyEhPanda** |
|--|---------------------------|-------------------|
| Base | Latest mainline | **v2.7.5** |
| Minimum OS | Raised (e.g. iOS 17 / 26 era tooling) | **iOS / iPadOS 16.0+** |
| Site / parser fixes after 2.7.5 | Yes | **Backported** |
| Liquid Glass / latest UI | Yes | **Not included** (keeps iOS 16 UI stack) |

Upstream 2.7.5 was the last line that still ran on iOS 16. Later releases fixed gallery preview parsing, EhSetting / thumbnail options, reading gestures, and other bugs, but dropped older OS support. This fork merges those **functional fixes** without raising the deployment target.

---

## Features (same family as EhPanda)

- Browse E-Hentai / ExHentai (with account / cookies where applicable)
- Search, favorites, history, filters
- Gallery detail, comments, torrents / archive entry points
- Reader with zoom / vertical & horizontal modes
- Host settings (uConfig) adapted to current site form fields
- Optional domain fronting / related network options from upstream 2.7.5

---

## System requirements

- **iOS / iPadOS 16.0** or later  
- Xcode that can still build with deployment target 16.0 (developed / built with modern Xcode; no Apple code signing identity is required for unsigned IPA packaging)

---

## Installation

1. Build an **unsigned** IPA (same approach as upstream AltStore CI), or use a release artifact if you publish one.
2. Install with tools such as:
   - [AltStore](https://altstore.io) / SideStore  
   - TrollStore (if available on your device)  
   - Sideloadly / similar sideloading tools  

### GitHub Actions (recommended)

This repo ships [`.github/workflows/release-ipa.yml`](.github/workflows/release-ipa.yml):

1. Open **Actions → Release IPA → Run workflow**
2. Optionally set a version (default: `CFBundleShortVersionString` from `Info.plist`)
3. When finished, the unsigned **`EhPanda.ipa`** is attached to a new [Release](https://github.com/12dora/LegacyEhPanda/releases)

You can also push a tag:

```bash
git tag v2.7.5
git push origin v2.7.5
```

### Build unsigned IPA (local)

```bash
# Example (adjust paths as needed)
xcodebuild build \
  -project EhPanda.xcodeproj \
  -target EhPanda \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  SYMROOT=build/Build

# Then package Payload/EhPanda.app into EhPanda.ipa (zip)
```

Signing: this fork is typically distributed **unsigned**, like many AltStore community builds. You must resign / sideload according to your tool of choice.

---

## What was backported (high level)

From post-2.7.5 upstream (non-exhaustive):

- Gallery preview parsing for current `gt100` / `gt200` layouts  
- EhSetting / thumbnail size / cover scale / page labeling adaptations  
- Thumbnail loading & preview batch behaviour fixes  
- Reading view gesture / scroll fixes (iOS 16–compatible APIs)  
- Various UI stability fixes (search empty title, EhSetting crashes, WebView safe area, etc.)  
- Extra hardening after local review (980x removal from picker, safer profile selection, preview page index math, etc.)

**Not** backported: TCA major upgrades, iOS 26 / Liquid Glass UI, raised deployment targets, experimental ReadingView rewrites that upstream later reverted.

App version label: **2.7.5 (build 151)** on this line of work.

---

## Project structure

```
LegacyEhPanda/
├── EhPanda/                 # App sources
├── EhPanda.xcodeproj/
├── EhPandaTests/
├── ShareExtension/
├── actions-tool/            # CI helpers (e.g. thin-payload)
├── READMEs/                 # Extra language readmes (upstream layout)
└── README.md                # This file (EN + 中文)
```

---

## Upstream & license

- Upstream project: [EhPanda-Team/EhPanda](https://github.com/EhPanda-Team/EhPanda)  
- This repository is a community **legacy / maintenance fork** for iOS 16.  
- Respect the original [LICENSE](./LICENSE) and copyright of EhPanda and its assets (including app icons).

Content shown in the app comes from E-Hentai / ExHentai and is user-generated. **Use at your own risk.**

---

## Disclaimer

- Unofficial client; not endorsed by E-Hentai or the EhPanda Team.  
- Site HTML and APIs change without notice; parsing may break again.  
- No warranty. You are responsible for compliance with local laws and site rules.

---

## Credits

- Original app and most of the architecture: **EhPanda Team** and contributors  
- Backport / iOS 16 maintenance line: **LegacyEhPanda** maintainers

---

# LegacyEhPanda (简体中文)

面向 **iOS 16** 的 [EhPanda](https://github.com/EhPanda-Team/EhPanda) 维护分支：以仍支持 iOS 16 的最后一版上游 **v2.7.5** 为底座，把后续版本中的**业务与站点兼容修复**回移植进来，从而在无法升级系统的设备上继续使用。

> 本仓库与 EhPanda 官方团队、E-Hentai 均无隶属关系。

## 为什么需要这个 Fork？

较新的官方版本在修复解析、站点设置、阅读手势等问题的同时，提高了系统要求。本仓库的目标是：

- **保留** `IPHONEOS_DEPLOYMENT_TARGET = 16.0`
- **享受** 2.7.5 之后的关键解析 / EhSetting / 预览与阅读相关修复  
- **不引入** iOS 26 Liquid Glass 等依赖新系统的 UI 改动  

## 系统要求

- iOS / iPadOS **16.0** 及以上  

## 安装

1. **推荐**：在 GitHub **Actions → Release IPA → Run workflow** 打包，完成后从 [Releases](https://github.com/12dora/LegacyEhPanda/releases) 下载 `EhPanda.ipa`。  
2. 也可推送标签 `v*` 触发同样流程，或本地按上文英文 **Build unsigned IPA** 自行编译。  
3. 通过 AltStore / SideStore / TrollStore / Sideloadly 等工具安装无签名包。

## 主要回移植内容（摘要）

- 当前站点缩略图 / 预览（含 `gt100` / `gt200`）解析  
- EhSetting、封面缩放、缩略图尺寸与行数等表单项适配  
- 阅读页手势与滚动（使用 iOS 16 可用 API）  
- 搜索空态标题、设置页稳定性等 UI 修复  
- 本地审查后的加固（如去掉已下线 980x、预览分页边界、xn_0 缺省等）  

当前应用版本标记：**2.7.5（build 151）**。

## 免责声明

- 非官方客户端，内容来自 E-Hentai / ExHentai 用户生成内容，**风险自负**。  
- 站点结构可能随时变化，解析逻辑可能再次失效。  
- 请遵守所在地法律法规与站点规定。  

## 致谢

- 原项目与主要架构：EhPanda Team 及贡献者  
- iOS 16 遗留维护线：LegacyEhPanda 维护者  

许可证与版权见 [LICENSE](./LICENSE) 及原项目说明。
