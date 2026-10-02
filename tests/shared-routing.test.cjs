const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');

test('shared suffix list adds both sites without dropping previous domains', () => {
  const text = read('rules/direct-domains.yaml');
  for (const domain of ['dmgh.cc', 'dmgh1.cc', 'dmgh2.cc', 'xifanacg.com', 'skr1.cc']) {
    assert.ok(text.includes(`'+.${domain}'`), `missing direct suffix: ${domain}`);
  }
});

test('keyword data is a separate classical rule rather than a domain-list entry', () => {
  assert.ok(fs.existsSync(path.join(root, 'rules/direct-keywords.yaml')), 'keyword data missing');
  assert.match(read('rules/direct-keywords.yaml'), /^\s+- DOMAIN-KEYWORD,dmgh\s*$/m);
  assert.doesNotMatch(read('rules/direct-domains.yaml'), /DOMAIN-KEYWORD/);
});

test('desktop global merge adds only a classical provider, not global rules', () => {
  const merge = read('desktop/Merge.yaml');
  const block = merge.match(/^  shared_direct_keywords:\r?\n(?: {4}[^\r\n]*\r?\n?)*/m)?.[0];
  assert.ok(block, 'keyword provider missing');
  assert.match(block, /behavior: classical/);
  assert.match(block, /format: yaml/);
  assert.match(block, /rules\/direct-keywords\.yaml/);
  assert.doesNotMatch(merge, /^rules:/m);
});

for (const file of ['desktop/SubscriptionRouting.template.yaml', 'desktop/SharedRouting.yaml',
  'desktop/GladosRouting.yaml', 'desktop/ThreeRouting.yaml']) {
  test(`${file} refers to keyword provider before ads without replacing subscription rules`, () => {
    const text = read(file);
    assert.equal(text.match(/RULE-SET,shared_direct_keywords,DIRECT/g)?.length, 1, 'keyword reference missing or duplicated');
    assert.ok(text.indexOf('shared_direct_domains') < text.indexOf('shared_direct_keywords'));
    assert.ok(text.indexOf('shared_direct_keywords') < text.indexOf('shared_ads'));
    assert.doesNotMatch(text, /^rules:/m);
  });
}

for (const rules of [['DOMAIN,example.com,Original', 'MATCH,Original'], ['DOMAIN,example.com,Original']]) {
  test(`mobile override preserves subscription rules ${rules.length === 2 ? 'with' : 'without'} MATCH`, () => {
    const context = vm.createContext({});
    vm.runInContext(read('clashmi-override.js'), context);
    const existing = {type: 'file', behavior: 'domain', path: './user.yaml'};
    const result = context.main({'rule-providers': {existing}, rules: [...rules]});
    assert.equal(result['rule-providers'].existing, existing);
    const provider = result['rule-providers'].shared_direct_keywords;
    assert.ok(provider, 'keyword provider missing in mobile override');
    assert.equal(provider.behavior, 'classical');
    assert.match(provider.url, /rules\/direct-keywords\.yaml$/);
    const actual = Array.from(result.rules);
    for (const rule of rules) assert.equal(actual.filter(item => item === rule).length, 1);
    assert.ok(actual.indexOf('RULE-SET,shared_direct_keywords,DIRECT') < actual.indexOf(rules[0]));
    if (rules.length === 2) {
      assert.equal(actual.at(-1), 'MATCH,Original');
      assert.ok(actual.indexOf(rules[0]) < actual.indexOf('RULE-SET,shared_cn_domain,DIRECT'));
    }
  });
}
