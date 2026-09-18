# Watt / Steamcommunity_302 本地加速自动切换

本目录提供 Windows Clash Verge Rev 的隐藏后台监控。它读取 Windows Hosts 和实际 TCP 监听状态，在订阅覆写文件的 `prepend` 中维护一个受控规则块。

| 状态 | 受控规则 | 优先级 |
| --- | --- | --- |
| 302 监听 80/443（Watt 可同时监听） | Hosts 域名 `DIRECT`，本地加速器自身进程使用配置的策略 | 302 |
| 仅 Watt 进程监听配置的 80/443 | Hosts 域名 `DIRECT`，Watt 自身进程使用配置的策略 | Watt |
| 两者都未监听 | 删除受控规则块，恢复订阅原有分流 | 订阅 |

脚本不修改 RRAS、IPv4 forwarding、路由、网卡、Windows portproxy、RDP 或 EasyTier。它也不自动开启/关闭 TUN；TUN 是否与本地加速器兼容仍取决于加速器自身的驱动和端口占用。

## 关键安全行为

- 每 3 秒采样，默认连续 2 次一致后切换。Hosts 内容变化也会触发同样的稳定采样；目标 YAML 被外部覆盖、手动修改或订阅刷新后，会重新对账。
- 脚本使用命名 Mutex 单实例保护。VBS 等待 PowerShell 退出并返回退出码，计划任务可以依据失败设置自动重启。
- 第一次启用 `EnsureSystemHosts` 时，脚本把每个订阅和 Merge 文件的原始 `dns.use-system-hosts` 状态写入私有 state 文件；两个加速器都停止后按原值恢复。原本没有该项时会移除脚本添加的项，不依赖 Merge 顺序。
- 多个文件先全部写入同目录临时文件并校验，再用 `File.Replace` 带时间戳备份原文件后替换。任一替换失败会尝试从已生成备份回滚；备份不会自动删除。
- 规则改变后可选择 `ClientRestartMode=Graceful` 或 `Fast`。两种模式都只匹配配置中路径严格相同的 `clash-verge.exe` GUI，不会操作 `clash-verge-service.exe`、`verge-mihomo.exe`、RRAS、302 或 Watt。Graceful 使用 `CloseMainWindow()` 并等待正常关闭；Fast 不调用 `CloseMainWindow()`，而是在所有同名进程路径核验通过后仅对已核验的 GUI PID 使用 `Stop-Process -Force`，确认退出后先等待 `FastRestartSettleMilliseconds`（默认 1000ms，允许 250–3000ms）释放 WebView2/单实例资源，再从相同路径启动。Fast 适用于 Clash Verge 托盘/WebView 失联语义，预计造成约 1–2 秒的代理/TUN 短暂中断；路径不匹配、终止失败或退出确认超时都会拒绝启动第二 GUI 并记录错误。规则文件虽已写入但未重启成功时不会即时加载，用户需要手动重启 Clash Verge。
- 可选的连接刷新只在运行 YAML 已确认包含 8 条有/无 `.exe` 的加速器进程规则、当前 Hosts `DIRECT` 规则完整且 `use-system-hosts=true` 后执行。它通过本机 Mihomo controller 查询连接；当前 Hosts 命中不受模式限制（覆盖浏览器/Steam 第一腿），仅进程名兜底按活动模式选择：`Steamcommunity_302` 只允许 302 的裸名/`.cli`/`.caddy`，`Watt` 只允许 `WattProcessName`/`Steam++.Accelerator`，共享 Steam 客户端和其他显式配置进程保持兜底。它会清理 fake-ip 缓存（若显式启用）并只逐条关闭选中连接，不调用无筛选的 `DELETE /connections`。controller secret 只从私有配置文件读入内存，不写日志、不提交 Git；接口失败只记录并继续监控。
- 推荐使用普通权限运行。脚本只需读取 Hosts、监听器并写入用户配置/日志；若用户配置路径要求管理员权限，任务应按实际 ACL 单独授权。

## 部署

1. 将本目录复制到稳定位置，例如 `C:\Tools\LocalAcceleratorRouting`。不要从临时下载目录或会被清理的 Codex 输出目录运行。
2. 复制 `LocalAcceleratorRoutingWatcher.config.example.psd1` 为同目录的 `LocalAcceleratorRoutingWatcher.config.psd1`，填写实际的订阅覆写路径。私有 config 不纳入 Git。
3. 首次用 `-Once` 执行一次规则对账：

```powershell
powershell.exe -NoProfile -File .\LocalAcceleratorRoutingWatcher.ps1 -Once -SkipClientReload
```

运行前请备份 Clash Verge 配置。该命令会按当前加速状态写入配置，不是只读检查；`-SkipClientReload` 只跳过客户端重启，不跳过文件校验、规则对账或已启用的连接刷新。首次部署保持示例中的 `ConnectionRefreshEnabled = $false`，确认覆写后再手动重新加载客户端。

## 从旧版 SteamRoutingWatcher 迁移

1. 备份现有订阅覆写、全局 Merge 和旧监控配置。在任务计划程序中禁用并结束旧监控任务，确认旧 `SteamRoutingWatcher.ps1` 进程已退出；不要同时启动新旧监控，旧版没有新版的 Mutex 单实例保护，新版也不能据此阻止旧版运行。
2. 将本目录源码、VBS、示例配置和测试部署到稳定目录。复制示例为私有 `LocalAcceleratorRoutingWatcher.config.psd1`，逐项填写路径；不要直接用公共示例覆盖已有私有配置。
3. 迁移旧配置中的 `Profiles` 和 `ClashExecutable`。旧的字符串路径列表仍可读取；需要设置加速器自身上游策略时，使用新版 `Path` / `AcceleratorPolicy` 结构。首次迁移建议保留 `ClientRestartMode = 'Disabled'`、`ConnectionRefreshEnabled = $false`。
4. 按上一节执行一次对账，检查配置后手动重新加载 Clash Verge Rev。新版识别并移除旧的 `BEGIN/END Steam accelerator routing` 受控块，再按实际状态生成新的 Local 块；不要把某次运行生成的域名名单粘贴为永久公共规则。
5. 将登录任务的操作改为本目录的 `LocalAcceleratorRoutingWatcher.vbs`，按下节设置任务恢复策略，再启用新任务。旧脚本可保留备查，但不继续运行。

若已部署新版，再次更新时先停止新版监控进程，更新源码、启动器和测试后重新启动；保留私有配置与原来的 `StatePath`、`BackupDirectory`。state 保存恢复 DNS 所需的原值，不能用空文件替换。

## 计划任务

创建任务时建议：

- 程序：`wscript.exe`
- 参数：`"C:\Tools\LocalAcceleratorRouting\LocalAcceleratorRoutingWatcher.vbs"`
- 触发器：用户登录时
- “使用最高权限运行”：关闭；只有实际文件 ACL 要求时才启用
- “失败后重新启动”：间隔 1 分钟，最多 3 次
- “如果任务已在运行”：不启动新实例

VBS 使用 `shell.Run(..., 0, True)` 等待监控进程，PowerShell 内部再用 Mutex 防止旧任务和新任务并存。任务显示 `Ready` 不代表监控进程当前存在，验证时应同时检查 `powershell.exe` 的 `-File LocalAcceleratorRoutingWatcher.ps1` 命令行和日志。

## 配置项

- `Profiles`：每个订阅覆写 YAML 的 `Path` 和本地加速器进程自身访问上游时使用的 `AcceleratorPolicy`。
- `GlobalMergePath`：可选的全局 Merge YAML；同样保存和恢复原始 DNS 状态。
- `EnsureSystemHosts`：启用本地加速时是否强制 Mihomo 使用 Windows Hosts。默认 `$true`，停用时恢复原值。
- `StatePath`：私有 DNS 快照文件。不要提交到 Git。
- `BackupDirectory`：原子替换生成的可恢复备份目录。不要提交到 Git。
- `ClientRestartMode`：`Disabled`、`Graceful` 或 `Fast`。示例默认 `Disabled`；本机私有配置可显式选择 `Fast`，会带来约 1-2 秒的代理/TUN 短暂中断风险。
- `RestartRunningClient`：旧配置兼容项；仅当未设置 `ClientRestartMode` 时生效。
- `FastRestartConfirmMilliseconds`：Fast 模式确认 GUI 退出的短上限，默认 500ms；超时不会启动第二个 GUI。
- `FastRestartSettleMilliseconds`：GUI 强制退出后、重新启动前等待 WebView2/单实例资源释放的时间，默认 1000ms，允许范围 250–3000ms。
- `WattProxyPorts` / `Steam302ProxyPorts`：实际服务监听端口，默认只认 80/443。仅监听 81/444 不会被误判为可用。
- `WattProcessName`：Watt 主进程名；连接刷新处于 `Watt` 模式时，按有/无 `.exe` 归一化后作为进程兜底。`Steamcommunity_302` 模式不会仅因 Watt 进程名关闭连接，反之亦然。
- `ConnectionRefreshEnabled`：是否允许在路由切换后查询并刷新 Mihomo 活动连接，示例默认关闭。
- `ConnectionRefreshFlushFakeIp`：是否在运行配置验证通过后调用 Mihomo `POST /cache/fakeip/flush`，示例默认关闭；启用会使 DNS/fake-ip 映射重新建立。
- `RuntimeConfigPath`、`MihomoControllerConfigPath`：运行 YAML 和本机 controller 配置路径；后者中的 secret 只在内存使用。可使用已配置的 `external-controller-pipe` named pipe，避免额外开放 HTTP 端口。
- `MihomoControllerAddress`：可选地址覆盖，仅填写本机回环地址，例如 `127.0.0.1:9090`，优先使用本机 named pipe。当前版本不会强制校验地址是否本机；HTTP 请求会携带 controller secret，因此不能填写远端或不可信地址。
- `ConnectionRefreshMaxConnections` / `ManagedConnectionProcesses`：定向关闭的数量上限和共享 Steam/其他自定义进程白名单；302 与 Watt 的进程兜底由活动模式和 `WattProcessName` 分别控制；超过上限时整次刷新拒绝执行。

## 排查

日志中重点查看：

- `Another watcher instance is already running`：已有实例，说明单实例保护生效。
- `Watcher iteration failed`：检查路径、文件权限、YAML 是否被 Clash Verge 锁定及 state 文件。
- `cannot request a graceful close` 或 `did not exit`：脚本没有强制终止 Clash；可手动重启客户端，规则文件和备份仍已完成。
- `accelerator priority: Steamcommunity_302`：302 优先于同时监听的 Watt。
- 302 监听识别同时兼容裸 steamcommunity_302 以及 .cli / .caddy 进程名；Mihomo 受控规则同时保留有/无 `.exe` 两套进程名，以兼容实际 metadata.process 语义。
- `Watt detected but not ready`：发现 Steam++/Steam++.Accelerator 进程但它没有在配置的 80/443 监听；日志会列出观察到的 81/444 等关联端口，此时不会切换到 Watt。
- `302 active; Watt is listening but is shadowed by Steamcommunity_302 priority`：302 正常优先，Watt 同时监听不代表未识别。

脚本只管理带有 `BEGIN/END Local accelerator routing` 标记的块，以及 state 文件记录的 `dns.use-system-hosts` 项；不要手工编辑受控块。

## 离线验证

在本目录运行两份回归测试：

```powershell
powershell.exe -NoProfile -File .\LocalAcceleratorRoutingWatcher.Fast.Tests.ps1
powershell.exe -NoProfile -File .\LocalAcceleratorRoutingWatcher.Diagnostics.Tests.ps1
```

预期分别输出 `FAST_OFFLINE_TESTS=PASS` 和 `DIAGNOSTICS_OFFLINE_TESTS=PASS`。测试只提取待测函数并使用模拟进程、监听器和连接，不启动实际监控、不终止真实客户端、不访问 controller。

Fast 测试覆盖路径不匹配拒绝终止、终止失败不启动第二 GUI，以及只终止已核验 GUI PID。Diagnostics 测试覆盖 Watt 监听和辅助进程归属判断、不同活动模式的连接筛选、8 条进程规则、969 个域名的大规则集审计及连接刷新前置检查。这些离线测试不能代替部署后的实际启停、配置重载验收。
