# Ghostty Windows 个人移植

这是 Ghostty 的个人 fork，当前工作分支为 `windows-port`。本分支在 Ghostty 共享终端核心上实现原生 Win32 桌面运行时，重点是让 Windows 上的标签页、分屏、窗口管理、剪贴板和日常 shell 工作流可用。它不是上游 Windows 官方实现，也不代表上游项目的支持状态。

## 当前功能

- 原生 Win32 窗口与终端 pane，支持 DPI 感知、多显示器、最小化/恢复和 Windows 窗口快捷键。
- 标签页、水平与垂直分屏、pane 焦点切换及 shell 退出后的 pane 清理。
- 标签栏溢出时提供左右翻页按钮；切换标签时自动显示活动项，右侧固定 `+` 保持新建标签与 shell 菜单可访问。
- 可拖动分屏分隔线。当前分隔线位置在 Frame 内共享，复杂嵌套布局和每条分隔线独立记忆比例仍未实现。
- ConPTY shell 启动、工作目录传递、终端标题更新和单实例新窗口/新标签 IPC。
- 中文输入的 Windows IME 支持，以及 Unicode 剪贴板复制、粘贴和危险多行粘贴确认。
- 标签栏 `+` 左键按默认配置创建标签，右键可选择 Nushell、PowerShell 7 或 Windows PowerShell。
- 终端通过 CPU 帧与 GDI 呈现；Windows WGL 呈现路径目前关闭。

本列表描述个人移植当前实现，不等同于所有配置和环境下的完整兼容承诺。架构背景、实现约束和已知限制见[Windows 移植说明](dist/windows/README.md)。

## Windows 构建与运行

要求 Windows 开发环境、Git，以及满足仓库 `build.zig.zon` 最低版本要求的 Zig。详细环境准备、代理、构建故障排查和测试说明见[Windows 中文构建指南](docs/windows-build-zh.md)。

```powershell
zig build
.\zig-out\bin\ghostty.exe
```

默认构建为 Debug。不要在 Ghostty 进程仍运行时覆盖其可执行文件；需要并行保留正在运行的版本时，可以使用独立输出前缀：

```powershell
zig build --prefix zig-out\dev
.\zig-out\dev\bin\ghostty.exe
```

## 回归测试

基础桌面冒烟测试：

```powershell
pwsh -NoProfile -File dist/windows/smoke-test.ps1
```

窗口、标签页、分屏、拖动调整、DPI、窗口控制和正常退出回归：

```powershell
pwsh -NoProfile -File dist/windows/test-window-chrome.ps1
```

剪贴板 Unicode、确认取消和多行粘贴确认回归：

```powershell
pwsh -NoProfile -File dist/windows/test-clipboard.ps1
```

这些脚本会操作真实桌面。运行前关闭其他 Ghostty 实例，并确认桌面已解锁；测试期间不要使用鼠标或键盘。个别测试会操作剪贴板或临时配置，具体行为以脚本说明为准。

## 文档

- [Windows 中文构建指南](docs/windows-build-zh.md)：环境准备、构建、代理及常见故障排查。
- [Windows 移植说明](dist/windows/README.md)：架构决策、性能观测、桌面测试和已知限制。
- [上游 README（原样归档）](docs/README-upstream.md)：此 fork 开始之前的上游项目介绍。
- 其他终端核心、配置与开发文档仍可从仓库对应目录查阅；本 README 只记录本分支相关信息。

## 与上游的关系

本仓库是个人维护的 Ghostty fork。上游项目的定位、贡献流程、发布、平台支持和路线图请以[上游 Ghostty 仓库](https://github.com/ghostty-org/ghostty)及其文档为准。本分支的改动和状态以当前 `windows-port` 分支为准。
