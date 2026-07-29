# 本地加速自动切换

> **适配范围：仅限 Windows 版 Clash Verge Rev。**
> 本脚本按照 Clash Verge Rev 的订阅覆写 YAML 和桌面程序重启方式编写，不能直接用于 Clash Mi、FlClash 或其他 Mihomo 客户端；这些客户端需要各自的覆写与重载适配。

本目录提供一个不使用 TUN 的隐藏后台监控。它检测 Watt 和 Steamcommunity_302 的实际加速服务状态，从 Windows Hosts 自动生成两款加速器接管的全部本机域名规则，并改写 Clash Verge Rev 的订阅覆写。

| 本地加速状态 | 写入的规则 | 实际接管者 |
| --- | --- | --- |
| 302 正在加速（包括 Watt 也在运行） | 从 Windows Hosts 自动生成全部本机加速域名的直连规则 | Steamcommunity_302 |
| 仅 Watt 正在加速 | 同上 | Watt |
| 两者都停止加速 | 删除受控规则块 | 原订阅规则 / Clash |
监控直接改写每个订阅的“高级 YAML 覆写”文件，因此**不依赖 Clash 是否已启动**。若 Clash 已在运行且配置开启自动重启，规则变更后会重启 Clash Verge Rev 立即生效；若 Clash 未启动，下次启动时会直接读取已更新的规则。

## 302 优先与自动域名同步

当前实测绑定方式为：Watt 监听 `0.0.0.0:80/443`，Steamcommunity_302 监听 `127.0.0.1:80/443`。两者同时运行时，Windows Hosts 将加速域名解析到 `127.0.0.1`，因此由绑定更具体回环地址的 Steamcommunity_302 接管。

| 检测结果 | 脚本行为 |
| --- | --- |
| 302 正在监听（Watt 可同时监听） | 写入全部本机 Hosts 加速域名的 `DIRECT`，302 优先 |
| 仅 Watt 正在监听 | 写入同一规则块，由 Watt 接管 |
| 两者都未监听 | 删除规则块，恢复订阅 |

规则不再只包含 Steam 或 GitHub。每次状态变化时，脚本读取 Windows Hosts 中所有指向本机回环地址的域名，自动生成受控规则；302 或 Watt 后续新增的服务无需手工维护域名清单。
## 检测方式

- **Steamcommunity_302**：只有 steamcommunity_302.cli 或 steamcommunity_302.caddy 进程实际监听配置的本地加速端口时，才视为加速已启动。单纯打开 302 的界面不会触发。
- **Watt**：只有 Steam++.Accelerator 实际监听本地加速端口时，才视为加速已启动。Watt 主界面或常驻模块本身不会触发。
- 默认每 3 秒检测一次，连续两次状态相同后才改规则，约 6 秒完成切换，以免服务启停瞬间反复重载。

## 使用前准备

1. 先按上级 [desktop/README.md](../README.md) 的步骤，为每个机场订阅添加 Clash Verge Rev 覆写。
2. 上级模板不会永久把 Steam 设为直连；Steam 动态规则只由本目录的监控脚本写入。
3. 将本目录整体复制到一个不会移动或删除的本机位置，例如 D:\ClashTools\steam-routing。

## 配置脚本

1. 将 LocalAcceleratorRoutingWatcher.config.example.psd1 复制为 LocalAcceleratorRoutingWatcher.config.psd1。
2. 用文本编辑器打开新文件，填写以下内容：

   - **Profiles**：所有需要一起切换的订阅覆写 YAML 的绝对路径。使用多个订阅时，每一份都要填入。
   - **ClashExecutable**：Clash Verge Rev 的 clash-verge.exe 绝对路径。
   - **RestartRunningClient**：设为 true 时，规则变化会重启当前正在运行的 Clash Verge Rev；设为 false 时只改规则文件，等下次手动启动 Clash 才生效。
   - **WattProxyPorts**：Watt 实际加速端口，默认是 80 和 443。若 Watt 以后更新并改变端口，可在此调整。
   - **Steam302ProxyPorts**：302 实际加速端口，默认是 80 和 443。
   - **EnsureSystemHosts**：默认 `true`。在单一加速器就绪时，覆写中会启用 Mihomo 的 `dns.use-system-hosts`，让 Clash 使用加速器写入的 Windows Hosts 记录，而不是直接解析到远端。
   - **LogPath**：留空会把日志写到脚本同目录的 LocalAcceleratorRoutingWatcher.log；也可填写任意可写入的绝对路径。

示例：

~~~powershell
@{
    Profiles = @(
        'C:\Users\你的账号\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev\profiles\订阅一.yaml'
        'C:\Users\你的账号\AppData\Roaming\io.github.clash-verge-rev.clash-verge-rev\profiles\订阅二.yaml'
    )
    ClashExecutable = 'E:\Clash\Clash Verge\clash-verge.exe'
    RestartRunningClient = $true
    PollSeconds = 3
    StableSamples = 2
    WattProcessName = 'Steam++.Accelerator'
    WattProxyPorts = @(80, 443)
    Steam302ProxyPorts = @(80, 443)
    EnsureSystemHosts = $true
    LogPath = ''
}
~~~

## 首次测试

使用“以管理员身份运行”的 PowerShell，进入脚本所在文件夹后执行：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\LocalAcceleratorRoutingWatcher.ps1 -Once
~~~

该命令只执行一次当前状态检测并写入对应规则，适合确认路径和权限是否正确。测试时：

- 只开启 Watt 或只开启 302，再执行一次，应写入 Steam 直连规则；
- 同时开启 Watt 与 302，再执行一次，应写入规则块并在日志中显示 302 优先；
- 两者都关闭，再执行一次，应删除该规则块并恢复订阅 Steam 规则。

## 设置为登录后自动后台运行

1. 打开 Windows 的“任务计划程序”，选择“创建任务”。
2. 在“常规”中勾选“使用最高权限运行”。
3. 在“触发器”中新增“登录时”触发。
4. 在“操作”中新增操作：
   - 程序或脚本：powershell.exe
   - 添加参数：`-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "LocalAcceleratorRoutingWatcher.ps1 的绝对路径"`
5. 保存任务后手动运行一次任务确认。

任务计划程序会以隐藏方式运行 PowerShell，因此不会出现或保留控制台窗口。不要关闭任务计划程序启动的后台任务；关闭它会停止自动切换。
## 脚本写入的规则

任一本地加速服务就绪后，脚本从 Windows Hosts 中收集所有指向本机回环地址的域名，在每份订阅覆写的 `prepend` 顶部自动写入受控 `DOMAIN` / `DOMAIN-SUFFIX,DIRECT` 规则。该规则块同时覆盖 Steam、GitHub 和两款软件后续新增的 Hosts 加速服务。

两者均停止时，脚本只删除带标记的受控规则块，不会改动机场订阅原有规则。请不要手动编辑标记之间的内容。
## 日志与排查

默认日志文件是脚本同目录的 LocalAcceleratorRoutingWatcher.log。常见内容含义：

- accelerator active: Watt; all local accelerator Hosts domains DIRECT：Watt 已接管。
- accelerator active: Steamcommunity_302; all local accelerator Hosts domains DIRECT：302 已接管。
- accelerator priority: Steamcommunity_302 selected while Watt is also listening：两个加速服务同时运行时，302 优先接管。
- no accelerator: restored to Clash subscription rules：两个加速服务均已停止，已恢复由订阅规则处理。

若规则未立即生效，请依次检查：

1. 配置中的 Profiles 是否指向当前正在使用的订阅覆写文件。
2. 任务计划程序是否正在运行，且任务使用最高权限。
3. Clash Verge Rev 是否已启动；若不希望自动重启，确认 RestartRunningClient 是否设为 false。
4. 查看日志中是否识别出 Watt 或 Steamcommunity_302。
