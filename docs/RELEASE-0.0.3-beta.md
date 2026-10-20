# 0.0.3 beta

- 发布本机已安装的 0.0.3 beta 基线，包括 Claude Code / Codex 权限请求与通知、用量显示和已有界面改进。
- 修复顶部刘海的截屏窗口选区包含大块下方透明区域的问题：静止细条窗口高度为 5 DIP，悬停刘海为 32 DIP；展开时按实际面板高度显示。
- 动画开始前扩展画布，最后一帧结束后通过 Dispatcher 延迟收紧窗口，避免在 Rendering 回调里调整分层窗口。
- 保持横向舞台布局，避免改变居中、拖动和权限卡锚点；本次修复针对多余的垂直透明区域。
- 新增 PowerShell 7 / Windows PowerShell 5.1 回归测试，以及 Windows 原生 HWND 尺寸集成测试。
- 修复打包脚本漏装 hooks/ 的问题，补充 Windows 原生构建脚本及安装包内容检查。

## 下载

- JayOS-AI-Usage-Setup-0.0.3-beta.exe：Windows x64 单文件安装器。
- JayOS-AI-Usage-0.0.3-beta.zip：可解压运行的应用包。
- SHA256SUMS.txt：以上文件的 SHA-256 校验值。

安装包尚未进行代码签名。本包不含本机凭证、用量缓存、设置、日志或请求文件。