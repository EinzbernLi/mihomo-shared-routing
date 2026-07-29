# Mihomo 路由共享规则

这是一套可复用的**补充规则**，适用于 Mihomo 内核的 Clash Verge Rev、Clash Mi 与 FlClash。仓库不包含机场订阅、节点、账户或任何凭据。

## 包含什么

- `rules/microsoft-store.yaml`：微软商店授权与下载域名直连
- `rules/direct-domains.yaml`：个人补充直连域名（当前为动漫共和国 `dmgh.cc`）
- MetaCubeX 数据集：中国大陆域名和 IP 直连、广告域名拦截
- `clashmi-override.js`：Android 的自动覆写脚本
- `desktop/`：Clash Verge Rev 的电脑端覆写模板
- 电脑端 Steam 域名直连，供 Watt、Steamcommunity_302 等本地加速工具接管

规则数据每 24 小时更新一次。仓库中的两份自建规则更新后，Android 与已配置的电脑端会在下一次规则提供者更新时获取新版本。

## 路由顺序

1. 自建直连（微软商店、动漫共和国）
2. 广告域名拦截
3. 机场订阅自带的专属规则和策略组
4. 中国大陆域名 / IP 直连兜底
5. 机场订阅的最终 `MATCH` 规则

这样不会用通用国内规则抢走机场对 Google、流媒体、Apple、Steam 等服务的专属分流。

## Android：Clash Mi

保留机场订阅，不要把本仓库当作机场订阅导入。

1. 打开 **核心设置 → 覆写**，点击右上角 `+`。
2. 选择 **添加配置链接**，填写：
   - 备注：`安卓路由共享`
   - URL：`https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/clashmi-override.js`
   - 类型：`js`
   - 更新间隔：`1 d`
   - 追加覆写：选择 **内置-覆写**
3. 保存后点击云朵图标更新，再断开并重新连接代理。

Clash Mi 的“规则提供者”页面只能添加规则数据，不能指定 `DIRECT` 或 `REJECT` 策略；因此应使用上面的 JS 覆写方式。

## Android：FlClash

保留原机场订阅。FlClash 的“脚本覆写”是本地脚本编辑器：新建脚本后，打开 `clashmi-override.js` 的 Raw 链接，复制全部内容并粘贴保存；再在机场订阅的覆写设置中绑定这个脚本。

1. 打开 **工具 → 进阶配置 → 脚本**，点击右上角 `添加`。
2. 打开 `clashmi-override.js` 的 Raw 链接，复制全部内容并粘贴保存。
3. 打开 **配置 → 选中机场订阅 → 更多 → 覆写 → 脚本**，在机场订阅的覆写设置中绑定这个脚本。
   
FlClash 的 URL 导入用于完整机场配置，不能把这份 JS 覆写脚本作为独立订阅导入。脚本本身如需更新需要手动重新粘贴一次；脚本引用的自建规则和 MetaCubeX 数据仍会每 24 小时自动更新。

## 电脑端：Clash Verge Rev

当前电脑已经配置完成。新电脑时：先导入机场订阅，再按 [desktop/README.md](desktop/README.md) 的逐步流程导入对应覆写模板。

**不要**在“全局扩展覆写配置”中添加顶层 `rules:`。该页面的 `rules` 会整体替换机场订阅原有规则；全局配置只用于本仓库的 `profile` 与 `rule-providers`。

微软商店在 Windows 上另需执行一次系统级“回环豁免”，否则它可能无法使用本机代理；这不是规则文件能代替的设置。可在 Clash Verge Rev 的工具/脚本中执行，或以管理员 PowerShell 运行：

```powershell
CheckNetIsolation LoopbackExempt -a -n=Microsoft.WindowsStore_8wekyb3d8bbwe
```

## 自定义规则维护

- 给某个网站直连：在 `rules/direct-domains.yaml` 的 `payload` 中添加 `+.example.com`。
- 给新的微软相关域名直连：添加到 `rules/microsoft-store.yaml`，格式为 `DOMAIN,hostname`。
- 提交到 `main` 分支后，已配置客户端将在下一次更新（最长约 24 小时）加载。

修改后应先检查 YAML 缩进与格式。规则文件写错会导致对应规则提供者无法更新，但不会包含或暴露订阅信息。

## Windows 本地加速自动切换

桌面模板不再永久把本地加速服务域名写成直连。若使用 Watt 或 Steamcommunity_302，并希望“302 运行时优先交给 302；仅 Watt 运行时交给 Watt；两者均停止时交回 Clash 订阅”，请使用 [desktop/local-accelerator-routing](desktop/local-accelerator-routing/README.md) 的后台监控脚本。

该脚本目前**仅适配 Windows 版 Clash Verge Rev**；它会从 Windows Hosts 自动读取两款加速器接管的全部本机域名，并在每份订阅覆写的 prepend 顶部临时写入受控直连规则；两者均停止后只删除该受控规则块。不使用 TUN，也不会在后台保留可见的 PowerShell 窗口。Clash Mi、FlClash 等客户端需要另行适配，不能直接使用该脚本。
