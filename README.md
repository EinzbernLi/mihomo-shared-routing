# Mihomo 路由共享规则

这是一套可复用的**补充规则**，适用于 Mihomo 内核的 Clash Verge Rev、Clash Mi 与 FlClash。仓库不包含机场订阅、节点、账户或任何凭据。

## 包含什么

- `rules/microsoft-store.yaml`：微软商店、Xbox 授权与下载域名直连
- `rules/direct-domains.yaml`：个人补充直连域名（`dmgh.cc`、`dmgh1.cc`、`dmgh2.cc`、`xifanacg.com`、`skr1.cc`，含子域名）
- `rules/direct-keywords.yaml`：域名关键词直连（`dmgh`，用于覆盖仍含该关键词的新域名）
- MetaCubeX 数据集：中国大陆域名和 IP 直连、广告域名拦截
- `clashmi-override.js`：Android 的自动覆写脚本
- `desktop/`：Clash Verge Rev 的电脑端覆写模板
- 电脑端按 Windows Hosts 动态生成直连规则，供 Watt、Steamcommunity_302 等本地加速工具接管

规则数据每 24 小时更新一次。仓库中的三份自建规则更新后，Android 与已配置的电脑端会在下一次规则提供者更新时获取新版本。

## 路由顺序

1. 自建域名与关键词直连、微软商店直连
2. 广告域名拦截
3. 机场订阅自带的专属规则和策略组
4. 中国大陆域名 / IP 直连兜底
5. 机场订阅的最终 `MATCH` 规则

这样不会用通用国内规则抢走机场对 Google、流媒体、Apple、Steam 等服务的专属分流。

## Android：Clash Mi

保留机场订阅，不要把本仓库当作机场订阅导入。

1. 打开 [clashmi-override.js Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/clashmi-override.js)，复制完整脚本。
2. 在 **核心设置 → 覆写** 中新建本地 JS 覆写，将脚本粘贴并保存，再绑定到原机场订阅。
3. 断开并重新连接代理。首次需要本地粘贴；之后规则数据自动更新，只有脚本逻辑改变才需要重新粘贴。

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

若回环豁免已存在，商店仍一直转圈并提示“初始化失败”，请按 [Windows 商店 DNS 排障说明](desktop/README.md#微软商店初始化失败可选-dns-修复)检查接口连接。仓库提供 [可选 DNS 覆写片段](desktop/MicrosoftStoreDns.optional.yaml)，仅在确认当前网络的系统 DNS 可用后启用；商店继续使用 `DIRECT`，默认桌面模板和手机端配置不受影响。

## 自定义规则维护

- 给某个网站直连：在 `rules/direct-domains.yaml` 的 `payload` 中添加 `+.example.com`。
- 域名关键词直连：在 `rules/direct-keywords.yaml` 中使用 `DOMAIN-KEYWORD,关键词`，由 `shared_direct_keywords` 指向 `DIRECT`。关键词规则不是域名列表，不能混入 `direct-domains.yaml`。
- 给新的微软相关域名直连：添加到 `rules/microsoft-store.yaml`，格式为 `DOMAIN,hostname`。
- 提交到 `main` 分支后，已配置客户端将在下一次更新（最长约 24 小时）加载。

`dmgh` 关键词按主机域名匹配，例如 `dmgh2.cc`、`www.dmgh3.cc`，而不是按网站名称、页面内容或 URL 路径识别。它也会匹配无关的、域名中含 `dmgh` 的网站；若网站完全改名，或图片/视频使用不含该关键词的第三方域名，仍需按实际连接补充规则。此宽泛匹配为明确选择，不应默认对其他网站添加关键词。

已有客户端首次启用关键词提供者需要一次逻辑升级：电脑端合并 `shared_direct_keywords` 提供者，并在每份订阅高级规则中加入 `RULE-SET,shared_direct_keywords,DIRECT`，不要覆盖手动修改；Clash Mi / FlClash 重新粘贴完整新版脚本一次。之后仅修改关键词数据或精确域名数据，不需要再粘贴。电脑端升级细节见 [desktop/README.md](desktop/README.md#新增关键词直连的已有用户升级)。

修改后应先检查 YAML 缩进与格式。规则文件写错会导致对应规则提供者无法更新，但不会包含或暴露订阅信息。

## Windows 本地加速自动切换

桌面模板不会永久把加速域名写成直连。若使用 Watt 或 Steamcommunity_302，请使用 [desktop/local-accelerator-routing](desktop/local-accelerator-routing/README.md) 的后台监控脚本。新版从 Windows Hosts 中读取指向回环地址的域名，不限于固定的 Steam 域名列表；只有检测到实际加速监听时才写入受控规则。

该脚本**仅适配 Windows 版 Clash Verge Rev**。它在每份订阅覆写的 prepend 顶部维护加速器进程规则和 Hosts 域名直连规则，保存并恢复原始 `dns.use-system-hosts` 状态；两种加速器同时可用时优先 302。脚本不自动切换 TUN，通过隐藏启动器后台运行。示例默认关闭客户端自动重启和活动连接刷新，这些功能需按说明显式配置。Clash Mi、FlClash 等客户端不能直接使用该脚本。

旧版 [desktop/steam-routing](desktop/steam-routing/README.md) 保留供已有部署查阅；升级请按新版 README 的迁移步骤操作，避免新旧监控同时改写同一份配置。监控程序的更新不随规则提供者的 24 小时刷新自动部署。
