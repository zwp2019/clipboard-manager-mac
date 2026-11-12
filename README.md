# 剪贴板管理器 for macOS

> # Clipboard Manager for macOS
>
> A native macOS clipboard history manager. It lives in your menu bar, and a press of `⌘⇧V` opens a card-style board at the bottom of the screen where you can browse, search, favorite, and paste anything you've copied: text, links, images, code, files, and even color values.
>
> Built with Swift Package Manager, AppKit, and SwiftUI. No third-party dependencies. Requires macOS 14+.
>
> 推广素材见 [docs/promotion.md](docs/promotion.md)。

一款原生 macOS 剪贴板历史管理工具。常驻菜单栏，一键呼出屏幕底部的「画板」，以卡片流的形式浏览、搜索、收藏和回贴最近复制过的所有内容——文本、链接、图片、代码、文件，乃至一张颜色色值，都能找回。

基于 **Swift Package Manager + AppKit + SwiftUI** 构建，无第三方依赖，使用系统 Vision 框架完成图片 OCR。

## 功能特性

### 记录与预览
- **全类型记录**：文本、链接、图片、代码、文件路径自动分类，`#RRGGBB` 色值文本会被识别为颜色卡片并直接可视化预览。
- **图片 OCR**：复制图片后自动在后台提取其中的文字（Vision 框架，本地识别），搜索时一并命中。
- **智能去重**：相同内容只保留一条，并自动移动到最前。
- **内容嗅探排除**：可指定应用名单，来自这些应用的复制内容不会被记录。

### 画板界面
- 屏幕底部横向卡片流，毛玻璃画板 + 不透明卡片，完整适配深浅色模式。
- 单击选中、**双击直接粘贴**到当前应用。
- 顶部快捷搜索（`⌘F`）与「剪贴板 / 收藏 / 收藏板」分组筛选。

### 粘贴与复制
- **双击或回车**：把选中内容粘贴回当前正在使用的应用（自动归还焦点后再模拟 `⌘V`）。
- **`⌘C`**：仅复制到剪贴板，不粘贴；也可选择「复制为纯文本」。
- 写入剪贴板时带有内部标记，不会把本应用的操作重复记录进历史。

### 收藏体系
- 收藏单个条目（星标），收藏内容不受历史清理影响。
- 创建多个**收藏板**（自定义名称与颜色），把常用片段归档成个人素材库。

### 存储与隐私
- 本地 SQLite 存储，数据保存在 `~/Library/Application Support/ClipboardManagerMac/`。
- 可配置历史保留天数（默认 30 天，0 = 永久）与最大条数（默认 50000 条）。
- 支持一键备份数据库。
- 全程本地运行，无任何网络请求。

## 快捷键

| 按键 | 功能 |
| --- | --- |
| `⌘⇧V` | 呼出 / 隐藏画板（全局快捷键，可在偏好设置中自定义） |
| `↑` `↓` `←` `→` | 在卡片间移动选择 |
| `Enter` | 粘贴选中内容到当前应用 |
| `⌘C` | 复制选中内容到剪贴板 |
| `F` | 收藏 / 取消收藏 |
| `Delete` | 删除选中条目 |
| `Space` | 打开大图预览详情 |
| `⌘F` | 聚焦搜索框 |
| `Esc` | 关闭画板，焦点交还原应用 |

## 系统要求

- macOS 14.0 或更高版本
- Apple Silicon 或 Intel Mac

## 构建与运行

```bash
# 克隆后直接构建完整 App（含图标与签名）
bash scripts/build_app.sh

# 产物位于
open build/剪贴板管理器.app
```

也可以仅用 SwiftPM 编译调试：

```bash
swift build
.build/debug/ClipboardManagerMac
```

首次使用建议在偏好设置中开启「登录时自动启动」，之后它只会安静地待在菜单栏里。

## 权限说明

| 权限 | 用途 | 是否必需 |
| --- | --- | --- |
| 辅助功能 | 双击/回车后向目标应用发送 `⌘V` 粘贴 | 可选，未授权时仍可复制后手动 `⌘V` |
| 无 | OCR 完全本地完成，不需要屏幕录制或网络权限 | — |

## 项目结构

```
Sources/ClipboardManagerMac/
├── App/          # 应用生命周期、面板控制、全局快捷键、菜单栏
├── Services/     # 剪贴板读写、录制管线、OCR
├── Data/         # SQLite 数据库与仓储层
├── Domain/       # 数据模型与设置
└── UI/           # SwiftUI 视图与设计 Token
scripts/
├── build_app.sh  # 一键构建 .app bundle
└── make_icon.swift 生成应用图标
```

## 技术要点

- **NSPanel + NSVisualEffectView**：无边框、不抢焦点的底部画板，关闭时自动把焦点归还给上一个应用，保证随后的 `⌘V` 落在正确的地方。
- **ChangeCount 轮询 + 内部写入标记**：0.35s 轮询系统剪贴板，通过私有 pasteboard 类型识别自身写入，避免回环录制；复制后短暂内存保护，防止剪贴板被其他工具抢占丢失。
- **协作式激活兼容**：针对 macOS 14+ 的应用激活机制做了双击启动、重复启动、登录项启动三种场景的适配。
