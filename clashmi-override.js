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
  providers.shared_xbox_services = {
    type: 'http',
    behavior: 'classical',
    format: 'yaml',
    interval: 86400,
    path: './ruleset/shared_xbox_services.yaml',
    url: 'https://raw.githubusercontent.com/EinzbernLi/mihomo-shared-routing/main/rules/xbox-services.yaml',
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

  const subscriptionRules = config.rules || [];
  const finalMatchRule = [...subscriptionRules].reverse().find(
    (rule) => typeof rule === 'string' && rule.trim().startsWith('MATCH,'),
  );
  const fallbackGroup = finalMatchRule
    ? finalMatchRule.trim().split(',').slice(-1)[0]
    : 'GLOBAL';
  const fixedRules = [
    // Fallback: apply immediately even before the remote custom list refreshes.
    'DOMAIN-SUFFIX,dmgh.cc,DIRECT',
    `DOMAIN-SUFFIX,xbox.com,${fallbackGroup}`,
    `DOMAIN-SUFFIX,xboxlive.com,${fallbackGroup}`,
    `DOMAIN-SUFFIX,xboxservices.com,${fallbackGroup}`,
    `DOMAIN-SUFFIX,xboxab.com,${fallbackGroup}`,
    `RULE-SET,shared_xbox_services,${fallbackGroup}`,
    'RULE-SET,shared_direct_domains,DIRECT',
    'RULE-SET,shared_ads,REJECT',
  ];
  const nationalRules = [
    'RULE-SET,shared_cn_domain,DIRECT',
    'RULE-SET,shared_cn_ip,DIRECT,no-resolve',
  ];
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
