# 休眠哨兵 · Sleep Guard

一个原生 macOS 菜单栏小应用，提醒电脑是否开启了**系统级禁止休眠**设置。

当 `SleepDisabled = 1` 时，菜单栏显示橙色图标与“休眠禁用”，并发送本地通知。允许休眠时显示绿色月亮；读取失败时显示灰色问号与“未知”。

> 本应用监测的是系统设置，不代表电脑已经睡着，也不能据此保证外接显示器等情况下合盖就会休眠。它不判断是哪款软件更改了设置。

## 功能

- 每 10 秒后台检测一次，系统唤醒后立即重查。
- 首次发现休眠禁用时提醒，持续禁用默认每 30 分钟重复提醒。
- 重复提醒可选只首次，或每 5 / 15 / 30 / 60 分钟。
- 显示最近检测时间、通知权限、读取或通知提交错误。
- 提供测试提醒、手动刷新和本次运行最近五条状态记录。
- 支持用户选择登录时启动，区分已启用与等待系统批准。
- 提供恢复命令说明与复制按钮；不会自行修改电源设置。
- 本地处理，无网络请求、无遥测、无第三方依赖。

## 系统要求

- macOS 13 或更高版本。
- 构建需要 Xcode Command Line Tools 或完整 Xcode，以及可用的 macOS SDK。
- 默认构建当前主机架构。Apple Silicon 已完成本地构建与运行检查；Intel 构建和 macOS 13 实机运行尚未验证。

## 从源码构建

```bash
git clone https://github.com/Niceb0y666/sleep-guard.git
cd sleep-guard
bash build.sh
open "dist/休眠哨兵.app"
```

如果尚未安装开发工具，运行 `xcode-select --install` 并完成系统安装提示。完整 Xcode 的许可协议需要由你自行阅读、接受。

`build.sh` 默认生成 `dist/休眠哨兵.app`，也接受输出目录：

```bash
bash build.sh "/path/to/output"
```

应用使用本地 ad-hoc 签名，未使用 Developer ID 证书或 Apple 公证。面向其他用户分发时，建议另行配置开发者签名与公证；此仓库不会关闭 Gatekeeper。

## 使用

1. 将构建出来的“休眠哨兵.app”拖入“应用程序”文件夹，再打开。
2. 在首次窗口中点击“启用通知”，按 macOS 提示允许通知。
3. 点击“测试提醒”，检查系统能否显示提醒；专注模式和通知样式可能影响横幅。
4. 如需持续监测，勾选“登录时启动”。等待批准时前往系统设置 → 通用 → 登录项。
5. 关闭状态窗口后继续监测；从菜单栏选择“退出休眠哨兵”后停止。

应用处于绿色状态时，菜单栏仅显示月亮图标；橙色状态显示“休眠禁用”；未知状态显示“未知”。

详细说明见 [使用指南](docs/USER_GUIDE.md)。

## 恢复系统休眠

从应用菜单打开“恢复休眠说明…”，复制下面的命令，在终端中执行并输入 Mac 登录密码：

```bash
sudo pmset -a disablesleep 0
```

随后点击“马上检测”。本应用的监测不需要管理员权限，也不会主动执行这条命令。

## 测试、诊断与打包

```bash
# 13 个解析案例；不改变电源设置
bash test.sh

# 编译并打包本地签名的 ZIP，校验解压后签名
bash package.sh

# 生成用于诊断的本地应用；package.sh 只保留 ZIP
bash build.sh

# 只读检查，输出 status 与 checkedAt 的 JSON
"dist/休眠哨兵.app/Contents/MacOS/SleepGuard" --diagnose
```

诊断状态为 `allowed`、`disabled` 或 `unknown: <原因>`；未知状态退出码为 1，其他状态为 0。应用图形界面打开期间也可独立运行诊断。

## 项目结构

```text
App.swift                  菜单栏、窗口、通知和登录启动
PowerMonitor.swift         只读 pmset 查询、解析、超时与防重入
PowerMonitorTests.swift    解析案例，可独立运行
Icon.swift / PackIcon.swift 应用图标生成
Info.plist                 应用包元数据
build.sh / test.sh / package.sh
docs/                      使用、设计、验证与排障文档
CHANGELOG.md               版本记录
```

## 文档

- [使用指南](docs/USER_GUIDE.md)
- [设计与状态模型](docs/DESIGN.md)
- [验证记录与已知限制](docs/VALIDATION.md)
- [常见问题与排障](docs/TROUBLESHOOTING.md)
- [版本记录](CHANGELOG.md)

## 开发边界

轮询期间短于检测间隔的状态变化可能不会被捕获。真实睡眠期间程序不运行定时检测，唤醒后才重查。退出应用后不会监测；选择“只在首次发现时”指本次运行中首次发现禁用或每次重新进入禁用状态。

通知提交成功不等于横幅已显示；登录项已注册不等于完成了实际登出、重登验证。具体检查证据见 [验证文档](docs/VALIDATION.md)。

仓库暂未添加开源许可证，公开可见性不代表授予复制、修改或再分发许可。

## 官方参考

- [Apple：通知授权](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [Apple：注册登录启动项](https://developer.apple.com/documentation/servicemanagement/smappservice/register())
- [Apple：启动项授权状态](https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.property)
