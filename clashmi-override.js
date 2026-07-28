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
  providers.shared_custom_ads = {
    type: 'http',
    behavior: 'classical',
    format: 'yaml',
    interval: 86400,
    path: './ruleset/shared_custom_ads.yaml',
    url: 'https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/rules/custom-ads.yaml',
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

  const fixedRules = [
    // Fallback: apply immediately even before the remote custom list refreshes.
    'DOMAIN-SUFFIX,dmgh.cc,DIRECT',
    'RULE-SET,shared_direct_domains,DIRECT',
    // Temporary, exact ad candidate; do not block the wider zjjieapi.com domain.
    'DOMAIN,tnc3-bjlgy.zjjieapi.com,REJECT',
    'RULE-SET,shared_custom_ads,REJECT',
    'RULE-SET,shared_ads,REJECT',
  ];
  const nationalRules = [
    'RULE-SET,shared_cn_domain,DIRECT',
    'RULE-SET,shared_cn_ip,DIRECT,no-resolve',
  ];
  const subscriptionRules = config.rules || [];
  const matchIndex = subscriptionRules.findIndex(
    (rule) => typeof rule === 'string' && rule.trim().startsWith('MATCH,'),
  );

  // Keep service-specific subscription rules first; use national rules only
  // as a fallback immediately before the subscription's final MATCH rule.
  config.rules = matchIndex >= 0
    ? [
        ...fixedRules,
        ...subscriptionRules.slice(0, matchIndex),
        ...nationalRules,
        ...subscriptionRules.slice(matchIndex),
      ]
    : [...fixedRules, ...subscriptionRules, ...nationalRules];
  return config;
}
