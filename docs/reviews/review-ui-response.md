# UI 审查修复答复

- 分支：`fix/ui`；基于已包含其他审查修复的集成版本。
- 范围：`docs/reviews/review-ui.md` 的发现 1～8。
- 流程：先新增测试并运行，确认各项在修改前失败，再修改实现并回归。新增测试使用普通 PowerShell 脚本，不依赖 Pester。

## 逐项处理

| 编号 | 结论 | 修改内容 | 回归验证 |
|---|---|---|---|
| 1 | 已修复 | `Format-PanelReset` 不再强制转换成字符串，复用 `Config.ps1` 的 `ConvertTo-DateTimeOffset`；`Format-Reset` 已由数据修复使用该函数，保持不变。历史样本逐条解析并排序，跳过损坏时间；四个服务商的刷新分别捕获异常。 | fr-FR、de-DE、en-GB、zh-CN 下验证 JSON 时间、Z 和 +00:00；用假窗口和点集合验证坏样本过滤、端点坐标；注入两个服务商刷新异常，验证其余服务商继续刷新。 |
| 2 | 已修复 | 新增 `Resolve-UninstallDir`，优先采用有应用标志文件的注册安装目录；无有效记录时仅允许有标志文件的源目录，拒绝根目录及未标记目录。卸载清理 hook 的 AppDir 和延迟删除目标使用同一解析结果。 | 下载目录与安装目录分离的夹具；验证目录选择、拒绝无标志目录，并对夹具中的 hook 配置实际执行注册与移除。仅提取 Setup 函数，未执行安装器。 |
| 3 | 已修复 | 新增共享的 `StateFile.ps1`。设置及安装语言保存均先写同目录唯一临时文件，再用 `File.Replace`／`File.Move` 原子替换；保留有效 `.bak`，主文件为空或损坏时读备份。不会用损坏主文件覆盖良好备份，异常时清理临时文件。 | 空主文件、截断 JSON、备份恢复、正常备份轮换；模拟写临时文件中途失败，验证原文件不变；同时覆盖安装语言保存失败及临时文件清理。 |
| 4 | 已修复 | 补齐菜单、显示器、平台链接、账号提示、告警标题与正文等 zh/ja/fr/ko 翻译；补充过期时间、额度和告警动态文案。新增可还原英文来源的 tooltip 翻译，覆盖 WPF 逻辑树、WinForms 菜单和刘海提示。数字规则支持法语千位空格（含 U+202F／U+00A0）。 | `I18n.Tests.ps1` 从 AST 收集实际菜单、账号和状态文字，加载 Requests 的翻译注册表；验证四种语言、完整告警正文、动态额度和到期提示、法语数字及 tooltip 来源还原，共 384 项。 |
| 5 | 已修复 | 悬停轮询读取实际鼠标按键状态，松开后清除遗留的 `NotchPressed`；新增纯函数 `Test-NotchHolding` 供轮询使用。 | 覆盖按下后在外部松开、仍在按住、鼠标悬停及固定状态；检查轮询实际接入该判断。 |
| 6 | 已修复 | 每次菜单打开时，按当前配置同步各档不透明度及“失去焦点时隐藏”的勾选状态。 | 假菜单验证启动后 60% 配置仅勾选 60%，再切换 100% 和隐藏开关，验证同步更新。 |
| 7 | 已修复 | 新增 `Resolve-InstallTarget`：无论所选目录是否为空，只要不是现有安装且目录名不是 `JayOS AI Usage`，均追加应用专用子目录；现有安装保持原路径。采用审查建议的安装目录隔离方案。 | 覆盖用户自选空目录、已有安装目录及已命名的应用目录；未执行真实安装或递归卸载。此修复不会擅自迁移历史安装。 |
| 8 | 已修复 | 取色器复用 `Get-WorkArea` 获取面板所在屏幕、经过 DPI 换算的工作区；用 `Get-CpPickerPosition` 计算位置。按窗口实际期望大小定位，限制尺寸以适应小工作区。 | 覆盖负坐标、上方显示器、错位副屏及小工作区，断言窗口位置与尺寸均在给定工作区内；不创建真实 UI。 |

## 双版本完整测试结果

实测版本：Windows PowerShell **5.1.26100.9711**、PowerShell **7.6.7**。

分别使用以下方式遍历全部测试，并检查每个子进程退出码：

```powershell
foreach ($t in Get-ChildItem tests\*.Tests.ps1) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $t.FullName
}
foreach ($t in Get-ChildItem tests\*.Tests.ps1) {
    pwsh -NoProfile -ExecutionPolicy Bypass -File $t.FullName
}
```

| 测试脚本 | Windows PowerShell 5.1 | PowerShell 7 |
|---|---|---|
| `AgentHooks.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `ClaudeRenewal.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `ClaudeUsageCache.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `CodexCredits.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `DataReview.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `I18n.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `Notices.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `OverlayCleanup.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `RequestReview.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `RequestSafety.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `ReviewRegressions.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `UiLogic.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |
| `UiReview.Tests.ps1` | 通过（退出码 0） | 通过（退出码 0） |

共 **13 份脚本 × 2 个版本，26 次运行全部通过**。新增 `UiReview.Tests.ps1` 为 **53 项**，新增 `I18n.Tests.ps1` 为 **384 项**；另通过 Windows PowerShell 5.1 对修改脚本的语法解析，以及 `git diff --check`。

完整回归中顺带修正了旧测试的环境问题：
- `DataReview`、`CodexCredits` 的临时夹具／日志移到 `tests/` 内；数据测试对 Claude 版本查询使用桩，不启动真实 CLI。
- `Notices` 直接向子进程输入管道写入 UTF-8 字节，避免 Windows 默认编码在 hook 读取前破坏 BOM 夹具。
- `UiLogic` 显式加载取色器数学测试需要的 `System.Drawing`，并加载共用日期转换函数。

## 安全与验证边界

未真实运行 Setup.ps1、Setup.vbs、Install.bat 或 Uninstall.bat，未写注册表，未访问真实账号凭据、用户代理配置或安装目录，未启动实际悬浮窗，未推送或修改远程仓库。测试读写均限于仓库内的测试夹具，结束后清理。

真实鼠标拖动、菜单视觉效果和多显示器混合 DPI 的交互验收尚未执行；本次以纯函数、AST 提取和假 UI 对象验证，避免影响所有者正在使用的电脑。
