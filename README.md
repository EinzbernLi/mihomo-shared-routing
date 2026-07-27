# Mihomo shared routing

Portable, rules-only routing overrides for Mihomo-based clients. This repository contains no subscription URLs, proxy nodes, or credentials.

## What it does

- Microsoft Store and Xbox entitlement endpoints: `DIRECT`
- Advertising domains: `REJECT`
- Mainland China domains and IP ranges: `DIRECT`
- All other traffic: left to the subscription's own rules and default proxy group

## Android clients

Keep your original airport subscription. Use `android-override.yaml` as a **custom override**, merged at the top of the subscription's rules. Do not import it as an independent subscription.

In FlClash, use the subscription's **Override / Custom** settings. In Clash Mi, use the subscription's **Custom overwrite** feature. Add the `rule-providers` block and ensure the four `rules` lines are inserted before the subscription's own rules.

The `shared_ms_store` rule provider is fetched from this repository every 24 hours, so changes to `rules/microsoft-store.yaml` reach mobile clients automatically.

## Notes

- The Microsoft Store rule uses `DIRECT`; when a client uses a local system proxy, the app may still connect to the local proxy first, and Mihomo then sends the matching traffic directly to Microsoft.
- The rules deliberately do not include an OpenAI policy. Different subscriptions use different proxy-group names; add that mapping locally to avoid breaking the selected route.
