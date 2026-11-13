# Windows 构建指南

本文适用于本仓库的 `windows-port` 分支，用于构建原生 Win32 版 Ghostty。

## 准备环境

- Windows 开发环境。
- Git。
- Zig：当前项目要求最低版本为 `0.17.0`，具体要求以根目录 `build.zig.zon` 中的 `minimum_zig_version` 为准。本机已使用 Zig `0.17.1` 成功构建。
- 首次构建需要联网下载依赖；网络不通时，可按下文配置本机代理。

在终端中确认工具可用：

```console
git --version
zig version
```

进入仓库根目录，确认当前分支：

```console
git status --short --branch
```

如果尚未切换到移植分支，先妥善处理当前未提交的修改，再执行：

```console
git switch windows-port
```

## 配置本机代理

如果依赖下载出现连接失败、超时或 HTTP 错误，可以使用本机代理。下面假设代理程序已启动，并在 `127.0.0.1:10808` 提供 HTTP 和 SOCKS5 代理；实际端口及支持的协议应以本机代理配置为准。

环境变量只影响当前终端及其随后启动的子进程。请在配置后，直接在同一个终端执行构建。不同工具对代理环境变量的支持可能不同，设置后仍需检查下载结果。

### CMD

以下 `set` 命令用于 Windows 命令提示符（CMD）：

```bat
set http_proxy=http://127.0.0.1:10808
set https_proxy=http://127.0.0.1:10808
set all_proxy=socks5://127.0.0.1:10808

set HTTP_PROXY=http://127.0.0.1:10808
set HTTPS_PROXY=http://127.0.0.1:10808
set ALL_PROXY=socks5://127.0.0.1:10808
```

Windows 环境变量名不区分大小写，因此以上大小写两组设置是重复的；这里保留完整写法，便于复制。

### PowerShell

PowerShell 设置环境变量需要使用 `$env:`，不能直接使用上面的 CMD 写法：

```powershell
$env:HTTP_PROXY = 'http://127.0.0.1:10808'
$env:HTTPS_PROXY = 'http://127.0.0.1:10808'
$env:ALL_PROXY = 'socks5://127.0.0.1:10808'
```

`HTTPS_PROXY` 使用 `http://` 表示通过 HTTP 代理隧道访问 HTTPS 地址，这个写法是有意的。

### 检查代理连通性

可在 CMD 或 PowerShell 中使用 `curl.exe` 显式指定代理，检查依赖服务器是否可访问：

```console
curl.exe -I -L --proxy http://127.0.0.1:10808 https://deps.files.ghostty.org/uucode-1fb73433bba5d93366c57f23ff2e9d7939746500.tar.gz
```

这是当前版本的一个依赖地址。项目更新后，如果地址失效，请从 `build.zig.zon` 中选择实际依赖 URL。代理建立连接时可能先返回 `200 Connection established`，还需要检查后续依赖服务器的响应。

显式指定代理的 curl 请求成功，只能确认该请求可达，不代表 Zig 一定会使用相同的代理路径。

## 编译

在仓库根目录执行：

```console
zig build
```

默认生成 Debug 版本，适合本地功能测试和开发。Windows 默认使用原生 Win32 runtime，无需额外指定 `-Dapp-runtime`。

首次构建会下载依赖并编译 Zig、C 和 C++ 代码，耗时通常比后续增量构建长。如果需要降低并行度，可使用：

```console
zig build -j1
```

`-j1` 只限制构建并行度，不是网络问题的解决办法。

成功后，可执行文件位于：

```text
zig-out\bin\ghostty.exe
```

## 运行与测试

在 PowerShell 中运行：

```powershell
.\zig-out\bin\ghostty.exe
```

在 CMD 中运行：

```bat
zig-out\bin\ghostty.exe
```

也可以在资源管理器中直接打开该文件。程序使用 GUI subsystem，正常启动不会额外打开一个控制台窗口。

手动测试时，可检查文字显示、中文输入、复制粘贴、滚动、标签页、分屏、窗口缩放，以及关闭 shell 后的退出行为。

仓库还提供需要真实桌面环境的冒烟测试：

```powershell
pwsh -NoProfile -File dist/windows/smoke-test.ps1
```

该命令需要 PowerShell 7（`pwsh`）。脚本会启动程序、操作窗口、设置剪贴板，并临时修改用户配置；已有配置会备份后恢复。运行前请保存正在测试的终端会话。脚本的检查范围有限，通过也不代表全部 Windows 功能已验证。

移植架构、性能记录和已知缺口见 [Windows 移植说明](../dist/windows/README.md)。

## 常见构建问题

### 依赖下载失败或返回 HTTP 400

先确认本机代理程序、端口和协议正确，在当前终端配置代理后重试 `zig build`。不要仅凭 HTTP 400 就判断是项目代码或依赖地址错误。

本机首次构建曾出现 Zig 下载返回 `400 Bad Request`，而 curl 可以正常下载相同 URL 的情况。如果仍然遇到该问题，可以先用 curl 下载报错的包，再交给 Zig 校验并缓存：

```console
curl.exe -fL --retry 2 --proxy http://127.0.0.1:10808 -o "%TEMP%\ghostty-dependency.tar.gz" "依赖的实际URL"
zig fetch "%TEMP%\ghostty-dependency.tar.gz"
```

以上示例用于 CMD；PowerShell 对应写法为：

```powershell
$archive = Join-Path $env:TEMP 'ghostty-dependency.tar.gz'
curl.exe -fL --retry 2 --proxy http://127.0.0.1:10808 -o $archive '依赖的实际URL'
zig fetch $archive
```

将占位 URL 替换为构建报错中的完整地址，并根据实际文件格式调整文件后缀。确认 curl 下载成功后再执行 `zig fetch`，将其输出的 Zig 包哈希与对应 `build.zig.zon` 的 `.hash` 比较，然后重试构建。

### 已缓存依赖，仍然报哈希不匹配或解包崩溃

Zig `0.17` 的压缩包缓存与项目下的解包目录是不同层次。本机首次构建曾遇到 `zig fetch` 返回预期哈希，但后续 `zig build` 解包后报哈希不匹配，并发生过一次构建进程崩溃。因此，单独执行 `zig fetch` 不保证能解决所有缓存问题。

遇到这种情况：

1. 记录 Zig 版本、完整错误、依赖 URL 和预期包哈希。
2. 确认下载包经 `zig fetch` 校验得到的哈希与清单一致，不要修改项目声明的哈希来绕过错误。
3. 检查项目下 `zig-pkg/` 中对应依赖的解包结果，尤其是是否多了一层归档顶层目录。
4. 必要时，在确认包哈希正确后，将包内容正确解压到 `zig-pkg/<预期包哈希>/`，使依赖文件直接处于该目录下，再重新构建。不同归档的目录布局不同，不要对所有包盲目套用同一条去除顶层目录的命令。

本机成功构建时，对受影响的包采用了 curl 下载、Zig 包哈希校验和手动解包的方式。该处理属于特定环境下的补救步骤，正常构建无需执行。

依赖清单和离线构建辅助脚本的说明见 [依赖文件说明](../deps/README.md)及 [fetch-zig-cache.sh](../nix/build-support/fetch-zig-cache.sh)。后者是 shell 脚本，不是可直接粘贴到 CMD 的命令。

### translate-c 参数警告

本机成功构建时出现过：

```text
warning: unknown argument '-fno-sanitize=undefined'
warning: unknown argument '-fno-sanitize-trap=undefined'
```

这两条警告在该次构建中没有阻止生成可执行文件。判断构建是否成功，应检查完整输出和命令退出状态；目录中存在旧的 `ghostty.exe` 不代表本次构建成功。

## 缓存与生成文件

- `.zig-cache/`：项目构建缓存。
- `zig-pkg/`：项目使用的依赖解包目录。
- `zig-out/`：构建输出。

这些目录已被 Git 忽略，无需提交。通常保留缓存可以加快后续构建；排查单个依赖问题时，优先处理对应包，避免清空全部缓存后重新下载所有依赖。
