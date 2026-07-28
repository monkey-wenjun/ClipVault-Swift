# ClipVault

用 Swift 编写的 macOS 剪贴板管理器。灵感来自 Paste，核心交互对齐：全局快捷键呼出底部面板、卡片式历史、标签集合、搜索筛选、快速粘贴。

纯 SwiftPM 可执行目标 + 打包脚本，无 Xcode 工程。

## 演示视频

[![花了一个晚上搓了个原本需要付费的app](https://i0.hdslb.com/bfs/archive/5b8d28fd9f08d6192a3389e672ed7a6049565d31.jpg)](https://www.bilibili.com/video/BV1jf3L6MEBh/)

## 功能

**剪贴板历史**
- 轮询 `NSPasteboard` 自动记录文本 / 颜色（hex 自动识别渲染色块）/ 图片
- 卡片展示内容预览、相对时间、来源应用图标、字符统计
- 去重、上限 500 条、保留策略（天 / 周 / 个月 / 年 / 永久）

**底部面板**（⇧⌘V 呼出）
- 横向卡片流，单击选中、双击粘贴、悬停高亮
- 搜索：全局搜索（历史 + 所有标签），去抖 150ms + 小写索引
- 筛选气泡（NSPopover）：按类型（文本/链接/颜色/图片）、来源应用、图钉板组合筛选
- 键盘：←/→ 选择、回车粘贴、⌘1…9 快速粘贴、⌘←/→ 切换标签、Delete 删除、Esc 关闭
- 多选：单击标记、⌘A 全选（可自定义）、Delete 批量删除、右键批量删除
- 标签栏：仅当前选中标签显示底色，其余标签无背景
- 默认选中「剪贴板」标签

**标签集合（Pinboard）**
- `+` 即建"未命名"标签，自动分配未占用颜色；双击重命名（失焦自动保存）
- 右键卡片「移动到集合」：移动语义，历史条目钉入后从列表移除，集合内条目永久保留（不受保留策略影响）

**同步**
- 通过同步目录（默认 iCloud Drive 下的 ClipVault 文件夹）镜像历史与集合
- 按条目 id 并集合并，图片双向拷贝；删除操作不传播

**隐私与安全**
- 全部落盘数据 AES-256-GCM 加密（`history.json` / `pinboards.json` / 图片 / 同步目录），密钥存系统 Keychain（优先 synchronizable 经 iCloud 钥匙串同步，未开启时自动降级本机存储）；旧明文数据启动时自动迁移
- 忽略应用程序列表、忽略机密内容（ConcealedType）、忽略瞬时内容（TransientType）
- 数据目录权限 0700、文件 0600

**其他**
- 粘贴行为可选：直接粘贴到当前活动应用（模拟 ⌘V）/ 仅写入剪贴板
- 暂停记录：5 分钟 / 30 分钟 / 1 小时 / 1 天，到期自动恢复
- 新文本项编辑器（B/I/U/S、字符统计、⌘↩ 创建）
- 自定义全局快捷键（Carbon RegisterEventHotKey）、登录时打开
- 菜单栏：左键呼出面板，右键菜单

## 构建与运行

要求：macOS 13+，Xcode（Swift toolchain）。

```bash
./build.sh && open build/ClipVault.app
```

`build.sh` 会用钥匙串中的 Apple Development 证书签名（没有则退回 ad-hoc）。
**不要**用 ad-hoc 长期使用：其签名哈希每次构建都变，会导致辅助功能授权和
Keychain ACL 在每次构建后失效。

**需要的权限**：
- 辅助功能（系统设置 → 隐私与安全性 → 辅助功能）：用于"粘贴到当前活动应用"（模拟 ⌘V）。
  无权限时自动降级为仅写入剪贴板。
- iCloud Drive（可选）：用于同步。

## 默认快捷键

| 快捷键 | 作用 |
| --- | --- |
| ⇧⌘V | 呼出 / 收起面板 |
| ⌥⌘F | 展开并对焦搜索框（再按清空并折叠） |
| ⌘A | 全选当前列表（仅面板打开时生效，不做全局注册） |
| ⌘1…9 | 快速粘贴前 9 条 |
| ← / → | 移动选择 |
| ⌘← / ⌘→ | 切换标签 |
| 回车 | 粘贴选中项 |
| Delete | 删除标记项 / 选中项 |
| Esc | 取消标记 → 关闭面板 |

全部可在 设置 → 快捷键 中重新录制。

## 常见问题

### 首次打开提示“已损坏”或“无法验证开发者”

因为 app 使用 Apple Development / ad-hoc 签名，没有提交 Mac App Store 公证，macOS Gatekeeper 可能会拦截：

- **“ClipVault.app 已损坏，无法打开。你应该将它移到废纸篓。”**
- **“无法打开 ClipVault.app，因为 Apple 无法检查其是否包含恶意软件。”**
- **“无法打开 ClipVault.app，因为无法验证开发者。”**

解决方法（按推荐顺序）：

1. **右键打开**：在 Finder 中右键（或按住 Control 点按）`ClipVault.app` → **打开**，在弹出的对话框中再次点击 **打开**。
2. **系统设置放行**：打开 **系统设置 → 隐私与安全性**，在“安全性”下面找到关于 ClipVault 的拦截记录，点击 **仍要打开**。
3. **移除隔离属性**（最可靠）：在终端执行
   ```bash
   xattr -d com.apple.quarantine /Applications/ClipVault.app
   ```
   然后重新打开 app。

> 注意：使用 ad-hoc 签名时 Gatekeeper 拦截会更严格，建议配置 Apple Development 证书后重新 `./build.sh`。

## 数据存储

位置：`~/Library/Application Support/ClipVault/`（全部加密）

- `history.json` — 剪贴板历史（AES-256-GCM）
- `pinboards.json` — 标签集合（AES-256-GCM）
- `images/` — 图片条目（加密 PNG）
- 密钥：Keychain（service `com.local.ClipVault`）

## 架构

```
Sources/MyPaste/
├── main.swift              # 入口，accessory 模式（无 Dock 图标）
├── AppDelegate.swift       # 装配各模块、菜单栏（左键面板/右键菜单）、定时暂停菜单
├── ClipboardItem.swift     # 条目模型与各类缓存
├── Pinboard.swift          # 标签集合模型与调色板
├── ClipboardMonitor.swift  # NSPasteboard 轮询，忽略应用/机密/瞬时过滤
├── HistoryStore.swift      # 历史与集合存储、AES-GCM 落盘、明文迁移、保留策略
├── CryptoService.swift     # AES-256-GCM + Keychain 密钥管理
├── SyncController.swift    # 同步目录镜像与并集合并
├── PanelController.swift   # 底部 NSPanel、键盘事件、筛选 NSPopover、视图模型
├── PanelView.swift         # SwiftUI 卡片流、顶栏、筛选气泡内容
├── PasteService.swift      # 回写剪贴板、激活目标应用、模拟 ⌘V
├── HotKeyManager.swift     # Carbon 全局热键注册
├── SettingsWindow.swift    # 设置（左侧边栏布局）、快捷键录制器、关于窗口
├── TextEditorWindow.swift  # 新文本项编辑器
└── AppSettings.swift       # UserDefaults 设置中心、快捷键模型
```

关键实现点：

- **性能**：过滤结果 Combine 管道预计算（搜索词去抖 150ms）、小写搜索索引缓存、
  分批加载（先 30 条，滚到底哨兵追加）、图标/图片/相对时间全缓存
- **多屏**：菜单锚定用 `convertPoint(fromScreen:)` 两步转换，避免全局坐标偏移
- **非激活面板**：键盘事件用本地 monitor 分发；文本编辑时放行编辑按键

## 分支说明

- `main`：基础版本，维护日常 UI 与交互修复。
- `feature/close-ticket-tagger`：在 `main` 基础上集成 CloseTicketTagger，
  自动创建「归因类型」集合并支持 `prefix + tag + suffix` 的粘贴拼接。

## 作者

阿文 · [www.awen.me](https://www.awen.me) · hi@awen.me
