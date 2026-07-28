# Clash Verge Rev 电脑端：

这些是“覆写模板”，不是机场订阅。先保留并更新原机场订阅，再按照下方两部分配置。

## 第 1 部分：所有订阅共用的规则提供者

这一步只做一次。它让电脑从本仓库下载微软直连、自定义直连等规则文件。

1. 在 Clash Verge Rev 左侧打开 **订阅** 页面，进入 **全局扩展覆写配置**。
2. 浏览器打开 [Merge.yaml Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/desktop/Merge.yaml)，复制全部内容。
3. 回到“全局扩展覆写配置”，全选编辑器内容并替换为刚复制的完整内容。
4. 点击 **保存**，然后重启 Clash Verge Rev。

此页面中只能保留 `profile:` 与 `rule-providers:`；**不要添加顶层 `rules:`**。全局扩展覆写中的 `rules:` 会整体覆盖机场规则，导致分流异常。

## 第 2 部分：为每个机场绑定规则覆写

这一步每个机场只做一次。它决定规则顺序：自建直连 → 广告拦截 → 机场专属规则 → 国内兜底 → 机场最终代理。

### Glados

1. 在 **订阅** 页面找到 Glados 配置，右键或打开配置菜单。
2. 选择 **编辑规则**，进入 **高级** YAML 编辑器。
3. 打开 [GladosRouting.yaml Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/desktop/GladosRouting.yaml)，复制全部内容。
4. 在高级编辑器中全选、替换并保存。
5. 更新 Glados 订阅后重连。

### 三毛机场

1. 在 **订阅** 页面找到三毛机场配置，右键或打开配置菜单。
2. 选择 **编辑规则**，进入 **高级** YAML 编辑器。
3. 打开 [ThreeRouting.yaml Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/desktop/ThreeRouting.yaml)，复制全部内容。
4. 在高级编辑器中全选、替换并保存。
5. 更新三毛订阅后重连。

### 其他机场

可先使用 [SharedRouting.yaml Raw 文件](https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/desktop/SharedRouting.yaml)。它提供自建直连和广告拦截，但不调整该机场的最终 `MATCH`，因此不会破坏未知的策略组名称。

若要给该机场也添加国内兜底，请复制 `ThreeRouting.yaml` 或 `GladosRouting.yaml` 作为起点，并将其中的 `MATCH,三毛机场` / `MATCH,Default Proxy` 改为该机场配置最后一条 `MATCH` 实际使用的策略组名称；不要新建策略组。

## 验证

1. 打开 **连接** 或日志页面，访问动漫共和国；应看到 `dmgh.cc` 使用 `DIRECT`。
2. 打开微软商店；相关请求应命中 `shared_ms_store` 并使用 `DIRECT`。
3. 国内网站在没有机场专属规则命中时，应命中 `shared_cn_domain` 或 `shared_cn_ip`，使用 `DIRECT`。
4. 广告域名应命中 `shared_ads` 并使用 `REJECT`。

更新机制：自建规则、微软规则、国内规则和广告规则每 24 小时更新一次；机场节点和机场自带规则仍由原订阅更新。
