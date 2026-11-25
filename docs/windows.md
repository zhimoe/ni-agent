# Ni 的 Windows 使用与打包

## 直接运行

从 `dist/windows` 选择 `x64` 或 `arm64`。Windows 的“设置 → 系统 → 关于 → 系统类型”会显示处理器架构。Intel 和 AMD 电脑通常选 `x64`。Windows on ARM 选 `arm64`。

把对应目录完整复制到 Windows，也可以把对应 ZIP 解压到一个新目录。进入该目录后，在 PowerShell 运行以下命令。

```powershell
.\ni.exe --version
.\ni.exe
```

`ni.exe`、两份 OpenSSL DLL 和 `cacert.pem` 应放在同一个目录。运行包已包含这四个文件以及许可证。Nim 和 C 编译器只用于从源码编译。使用 `bash` 工具时可安装 Git for Windows。

| 文件 | 作用 |
| --- | --- |
| `ni.exe` | Ni 主程序 |
| `libssl-3*.dll` | HTTPS 的 TLS 库 |
| `libcrypto-3*.dll` | TLS 所需的加密库 |
| `cacert.pem` | 用于验证 HTTPS 服务证书的 CA 证书包 |

Ni 默认读取 `%USERPROFILE%\.pi\agent` 中的 Pi 配置。以 OpenAI 为例，在 PowerShell 运行 `.\ni.exe auth login openai` 会提示输入凭据。保存后再运行 `.\ni.exe`。

## 在 macOS 或 Linux 重新打包

准备 Nim、Zig 和 Python 3.11 或更新版本。从 Ni 源码根目录运行。

```sh
python3 scripts/package_windows.py
```

脚本会编译两个架构，从 Git for Windows 下载匹配的 DLL 和 CA 证书，并核对下载摘要和二进制架构。只需要一种架构时可以加 `--arch x64` 或 `--arch arm64`。产物都在 `dist/windows`。

## 在 Windows 编译当前架构

准备 Nim 和可用的 C 编译器。从 Ni 源码根目录运行以下命令，然后用新编译的 `ni.exe` 替换同架构运行目录里的 `ni.exe`。

```powershell
nim c -d:release -o:ni.exe src/ni.nim
```

| 架构 | 默认 DLL 文件名 |
| --- | --- |
| x64 | `libssl-3-x64.dll`、`libcrypto-3-x64.dll` |
| ARM64 | `libssl-3.dll`、`libcrypto-3.dll` |
