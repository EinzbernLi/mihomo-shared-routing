# Clash Verge Rev 电脑端导入说明

这些文件是“覆写模板”，不是机场订阅。先导入并更新三毛 / Glados 等机场订阅，再在 Clash Verge Rev 的覆写管理中创建或导入以下三种配置：

- 所有订阅共用的规则提供者：`Merge.yaml`
- 三毛机场：`ThreeRouting.yaml`
- Glados：`GladosRouting.yaml`

将 `Merge.yaml` 设为全局 Merge 覆写；将后两者分别绑定到同名机场订阅的规则覆写。保存并重启 Clash Verge Rev 后，观察日志中 `shared_direct_domains`、`shared_ms_store`、`shared_cn_domain`、`shared_cn_ip`、`shared_ads` 是否开始更新。

## 验证

- 打开动漫共和国；连接日志应显示 `DomainSuffix(dmgh.cc) using DIRECT`。
- 打开微软商店；连接日志应匹配 `shared_ms_store` 并使用 `DIRECT`。
- 国内网站应在机场专属规则没有命中时匹配 `shared_cn_domain` 或 `shared_cn_ip`，使用 `DIRECT`。
- 广告域名应命中 `shared_ads` 并使用 `REJECT`。

如果订阅的最终策略组名称与模板不同，必须把模板中的 `MATCH,三毛机场` 或 `MATCH,Default Proxy` 改为该订阅实际的最终 `MATCH` 名称；不要新建策略组。
