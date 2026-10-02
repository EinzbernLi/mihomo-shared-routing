# Clash Verge Rev 电脑端：通用导入流程

这些文件是“覆写模板”，不是机场订阅。先导入并更新你自己的机场订阅，再完成下方两部分配置。流程不依赖任何特定机场或策略组名称。

## 第 1 部分：配置所有订阅共用的规则提供者

这一步只做一次。它让电脑自动下载本仓库中的微软直连、自定义域名与关键词直连规则，以及国内/广告规则数据。

1. 在 Clash Verge Rev 左侧打开 **订阅** 页面，进入 **全局扩展覆写配置**。
2. 浏览器打开 [Merge.yaml Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/desktop/Merge.yaml)，复制全部内容。
3. 回到“全局扩展覆写配置”，全选编辑器内容，粘贴刚复制的完整内容。
4. 点击 **保存**，重启 Clash Verge Rev。

本仓库模板只提供 `profile:` 与 `rule-providers:`；**不要添加顶层 `rules:`**。全局扩展覆写中的 `rules:` 会整体覆盖机场原有规则，导致分流异常。若启用下方可选的本地加速监控，它可以额外管理 `dns.use-system-hosts` 并在停用加速后恢复原值。

## 第 2 部分：为每个订阅配置通用规则覆写

这一步每个机场订阅只做一次。规则的最终顺序是：

`自建直连 → 广告拦截 → 机场专属规则 → 国内兜底 → 机场最终 MATCH`

### 完整模式（含国内兜底）

1. 在 **订阅** 页面找到要配置的订阅，右键或打开配置菜单。
2. 选择 **编辑规则**，进入 **高级** YAML 编辑器。
3. 先记下该订阅原配置最后一条规则的策略组名称，即 `MATCH,策略组名称` 中逗号后的部分。例如最后一条是 `MATCH,自动选择`，就记下 `自动选择`。
4. 打开 [SubscriptionRouting.template.yaml Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/desktop/SubscriptionRouting.template.yaml)，复制全部内容。
5. 将模板内两处 `YOUR_FINAL_PROXY_GROUP` 都替换为第 3 步记下的策略组名称。
6. 在高级编辑器中全选、粘贴替换后的完整内容并保存。
7. 更新该订阅后重连。

不要新建策略组；模板使用该订阅原本的最终策略组，因此不会改变你原有的节点选择方式。

### 安全模式（仅自建直连与广告拦截）

如果暂时无法确认订阅最终 `MATCH` 的策略组名称，可使用 [SharedRouting.yaml Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/desktop/SharedRouting.yaml)。它只加入自建直连和广告拦截，不调整该订阅的最终路由；稍后确认名称后，再切换至上面的完整模式。

## 验证

1. 打开 **连接** 或日志页面，访问 `www.skr1.cc` 或 `dmgh2.cc`；应看到 `shared_direct_domains` 使用 `DIRECT`。不在精确列表中但域名仍含 `dmgh` 的请求应命中 `shared_direct_keywords`、使用 `DIRECT`。
2. 打开微软商店；相关请求应命中 `shared_ms_store` 并使用 `DIRECT`。
3. 国内网站在没有机场专属规则命中时，应命中 `shared_cn_domain` 或 `shared_cn_ip`，使用 `DIRECT`。
4. 广告域名应命中 `shared_ads` 并使用 `REJECT`。

## 微软商店初始化失败：可选 DNS 修复

适用症状：Windows 微软商店启动后一直转圈，随后提示“Microsoft Store 初始化失败”；事件日志可能包含 `0x80072EFD` 或请求超时。**错误码本身不能证明是 DNS 故障，应先核对下面的证据。**

### 先区分回环豁免与直连故障

1. 在实际登录的 Windows 用户上下文运行 `CheckNetIsolation LoopbackExempt -s`，确认包含 `Microsoft.WindowsStore_8wekyb3d8bbwe`。若从其他账户或沙箱检查，名称显示为 `AppContainer NOT FOUND` 不足以证明原用户的豁免丢失。缺少豁免时，按仓库首页说明添加。
2. 在 Clash Verge Rev 的连接或日志页面确认商店域名命中 `shared_ms_store`、出口为 `DIRECT`。系统代理指向本机 Clash 与商店直连并不矛盾：请求进入本机 Clash 后，由 `DIRECT` 直接连接服务器，不经过代理节点。
3. 检查事件查看器的 `Microsoft-Windows-Store/Operational` 日志，确认失败请求是否指向 `storeedge.microsoft.com` 的 `/v9.0/pages/home`、`/v9.0/pages/chrome` 或 `/v9.0/callerspecificdata/`。结合 Clash 内核实际 DNS 结果，与 `Resolve-DnsName storeedge.microsoft.com -Type A` 的系统解析结果对比；仅比较 IP 不足以验收，还应保留证书校验测试 HTTPS 可达性。

2026-09-26 的一次 Windows 实测中，豁免存在、商店包状态正常、直连规则已命中，但内核公共 DNS 选到的 CDN 地址连接失败；改用该网络的系统 DNS 后，三个接口均返回 `200`，连接仍为 `DIRECT`，商店界面也恢复。此结论只适用于当时测试的网络，不代表系统 DNS 在所有网络都更好，也不应将当时可达的 CDN IP 固定写入 Hosts。

### 按需合并配置

确认系统 DNS 能提供可达地址后，使用 [MicrosoftStoreDns.optional.yaml](MicrosoftStoreDns.optional.yaml)。它是配置片段，不是完整订阅，也不是可放入“规则提供者”的域名规则集：

```yaml
dns:
  nameserver-policy:
    'storeedge.microsoft.com': system
```

1. 先备份 Clash Verge Rev 的“全局扩展覆写配置”。
2. 将片段合并到**已有的** `dns.nameserver-policy` 中：已有 `dns:` 或 `nameserver-policy:` 时复用该键，不要重复创建；该域名已有策略时先记录原值。保留 `profile`、`rule-providers`、其他 DNS 策略及本地加速监控维护的 `dns.use-system-hosts`，不要用片段覆盖整个文件。
3. 在最终运行配置中确认 DNS 已启用，且该域名的策略确实为 `system`。若配置了 `direct-nameserver`，还需检查 `direct-nameserver-follow-policy`：为 `false` 时，直连重解析可能不采用这项策略。只有核对其他域名策略的影响后，才考虑将其设为 `true`；本片段不自动修改这个全局选项。参考 [Mihomo DNS 文档](https://wiki.metacubex.one/config/dns/)。
4. 保存并通过 Clash Verge Rev 重新加载配置，随后关闭商店窗口再重新打开。只编辑未启用的独立 DNS 设置文件不会生效。`system` 使用当前系统的解析器；若系统 DNS 又指回同一个 Mihomo DNS 监听器，应先排除解析循环。

现有 `shared_ms_store → DIRECT` 规则保持不变；此片段不会切换 TUN、系统代理、端口或机场节点，也不修改 Windows 系统 DNS。无需将这一 Windows 网络环境下的修复复制到 Clash Mi / FlClash 的共享规则中。默认 `Merge.yaml` 保持通用配置，本片段不自动启用。

### 验收与回退

- 商店主页和初始化恢复；连接或日志中的商店请求仍命中 `shared_ms_store`，出口为 `DIRECT`。仅浏览器能访问商店网站，不足以证明商店应用已恢复。
- 核对原有规则顺序、机场节点选择、端口和 TUN 状态未改变。切换到另一份订阅后，检查最终配置是否仍包含这项策略，并复核直连；订阅自身的 DNS 覆写可能改变合并结果。
- 若换网络后无效或产生问题，将该域名的策略恢复为原值；若原先没有该项，则仅移除本次添加的域名项及因此产生的空映射，保留其他 DNS 内容，然后重新加载。也可以在确认没有后续改动需要保留时恢复备份。
- 网络请求恢复前，不应把清空缓存、重置或重装商店作为该 DNS 问题的首选处理；网络已恢复但应用仍失败时，再检查应用缓存、账户及其他日志。

## 本地加速自动切换（可选）

上述覆写模板不会固定加速域名的路由。若安装了 Watt 或 Steamcommunity_302，可使用 [local-accelerator-routing/README.md](local-accelerator-routing/README.md) 中的后台监控。**该监控仅适配 Windows 版 Clash Verge Rev，不能直接用于 Clash Mi 或 FlClash。**

- 任一加速服务实际监听时，按 Windows Hosts 动态生成域名直连规则，并把加速器进程规则放在受控块前面；同时可用时优先 302。
- 两者都停止时，移除受控规则块并恢复原始 `dns.use-system-hosts` 状态，交回订阅分流。
- 示例默认不自动重启客户端、不刷新活动连接；修改后的覆写需由客户端重新加载。需要自动处理时，按新版说明配置对应选项。
- 脚本不自动切换 TUN；通过隐藏的脚本宿主运行，不会出现常驻 PowerShell 窗口。
- 旧版 Steam 监控用户先按新版说明迁移，不能同时运行两套监控。

## 更新机制

- 机场节点与机场自带规则：按原订阅自身的更新方式更新。
- 自建域名与关键词直连、微软直连、国内规则、广告规则：每 24 小时更新一次。
- `MicrosoftStoreDns.optional.yaml` 是按需手动合并的 DNS 配置；规则提供者的 24 小时刷新不会应用或更新它。已有用户需要自行合并并重新加载，已完成本机修复的用户无需重复操作。
- 若更改了 `SubscriptionRouting.template.yaml` 的规则逻辑，需要在每个已配置订阅的高级规则编辑器中重新粘贴一次；普通规则数据更新无需重复操作。
- 本地监控脚本、启动器和测试需要单独更新，不随规则提供者刷新自动下载；私有配置、state、日志和备份保留在本机。

## 新增关键词直连的已有用户升级

保留已有配置，不要全选覆盖。首次加入 `shared_direct_keywords` 时：

1. 备份“全局扩展覆写配置”和每份订阅的高级规则。
2. 从新版 `Merge.yaml` 仅复制 `shared_direct_keywords` 配置块，合并到现有 `rule-providers:` 下；保留原有 DNS、下载方式和其他手动设置，不新增顶层 `rules:`。
3. 在每份订阅的 **编辑规则 → 高级** 中，在 `prepend:` 的 `RULE-SET,shared_direct_domains,DIRECT` 后添加 `RULE-SET,shared_direct_keywords,DIRECT`，不要修改本地加速器受控块或原有策略组名。
4. 保存并重新加载，更新这两个共享直连规则集；旧连接可能仍使用原出口，重新打开相关页面后查看新连接。

`dmgh` 会匹配所有域名中含该字符串的请求，包括可能无关的网站。它不能识别完全不含 `dmgh` 的新域名，也不会把不含关键词的第三方视频/CDN 一并设为直连。这种情况仍需补充精确域名；回退时仅移除该关键词引用及提供者，保留其他内容。
