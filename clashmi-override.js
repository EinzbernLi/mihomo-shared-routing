// Clash Mi Android shared routing override.
// Keeps the subscription's existing rules and prepends shared routing rules.
function main(config) {
  const providers = config['rule-providers'] || {};

  providers.shared_direct_domains = {
    type: 'http',
    behavior: 'domain',
    format: 'yaml',
    interval: 86400,
    path: './ruleset/shared_direct_domains.yaml',
    url: 'https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/rules/direct-domains.yaml',
  };
  providers.shared_cn_domain = {
    type: 'http',
    behavior: 'domain',
    format: 'mrs',
    interval: 86400,
    path: './ruleset/shared_cn_domain.mrs',
    url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs',
  };
  providers.shared_cn_ip = {
    type: 'http',
    behavior: 'ipcidr',
    format: 'mrs',
    interval: 86400,
    path: './ruleset/shared_cn_ip.mrs',
    url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs',
  };
  providers.shared_ads = {
    type: 'http',
    behavior: 'domain',
    format: 'mrs',
    interval: 86400,
    path: './ruleset/shared_ads.mrs',
    url: 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/category-ads-all.mrs',
  };
  config['rule-providers'] = providers;

  const sharedRules = [
    // Fallback: apply immediately even before the remote custom list refreshes.
    'DOMAIN-SUFFIX,dmgh.cc,DIRECT',
    'RULE-SET,shared_direct_domains,DIRECT',
    'RULE-SET,shared_ads,REJECT',
    'RULE-SET,shared_cn_domain,DIRECT',
    'RULE-SET,shared_cn_ip,DIRECT,no-resolve',
  ];
  config.rules = [...sharedRules, ...(config.rules || [])];
  return config;
}
