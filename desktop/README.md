# Clash Verge Rev 电脑端：通用导入流程

这些文件是“覆写模板”，不是机场订阅。先导入并更新你自己的机场订阅，再完成下方两部分配置。流程不依赖任何特定机场或策略组名称。

## 第 1 部分：配置所有订阅共用的规则提供者

这一步只做一次。它让电脑自动下载本仓库中的微软直连、自定义直连规则，以及国内/广告规则数据。

1. 在 Clash Verge Rev 左侧打开 **订阅** 页面，进入 **全局扩展覆写配置**。
2. 浏览器打开 [Merge.yaml Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/desktop/Merge.yaml)，复制全部内容。
3. 回到“全局扩展覆写配置”，全选编辑器内容，粘贴刚复制的完整内容。
4. 点击 **保存**，重启 Clash Verge Rev。

此页面只能保留 `profile:` 与 `rule-providers:`；**不要添加顶层 `rules:`**。全局扩展覆写中的 `rules:` 会整体覆盖机场原有规则，导致分流异常。

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

1. 打开 **连接** 或日志页面，访问动漫共和国；应看到 `dmgh.cc` 使用 `DIRECT`。
2. 打开微软商店；相关请求应命中 `shared_ms_store` 并使用 `DIRECT`。
3. 国内网站在没有机场专属规则命中时，应命中 `shared_cn_domain` 或 `shared_cn_ip`，使用 `DIRECT`。
4. 广告域名应命中 `shared_ads` 并使用 `REJECT`。

## Steam 本地加速自动切换（可选）

上述覆写模板不会固定 Steam 的路由。若安装了 Watt 或 Steamcommunity_302，可使用 [steam-routing/README.md](steam-routing/README.md) 中的后台监控。**该监控仅适配 Windows 版 Clash Verge Rev，不能直接用于 Clash Mi 或 FlClash。**

- 302 正在运行时（即使 Watt 也在运行），自动在 prepend 顶部写入 Windows Hosts 中全部本机加速域名的直连规则，由 302 接管。
- 302 停止且 Watt 正在运行时，同一批规则由 Watt 接管；两者都停止时，自动删除该受控规则块，恢复订阅自己的分流。
- 不需要 TUN；通过隐藏的脚本宿主运行，不会出现常驻 PowerShell 窗口。

## 更新机制

- 机场节点与机场自带规则：按原订阅自身的更新方式更新。
- 自建直连、微软直连、国内规则、广告规则：每 24 小时更新一次。
- 若更改了 `SubscriptionRouting.template.yaml` 的规则逻辑，需要在每个已配置订阅的高级规则编辑器中重新粘贴一次；普通规则数据更新无需重复操作。
