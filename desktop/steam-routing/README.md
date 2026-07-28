# Steam local accelerator automatic switching

> **Supported client: Clash Verge Rev on Windows only.** This watcher is
> designed for Clash Verge Rev subscription override YAML files and its desktop
> executable restart flow. It does not support Clash Mi, FlClash, or other
> Mihomo clients without a separate adapter.

This folder provides a no-TUN background watcher for Clash Verge Rev. It
changes Steam routing automatically:

| Watt / Steamcommunity_302 state | Steam rules written | Traffic handler |
| --- | --- | --- |
| Either acceleration service is active | Seven DOMAIN-SUFFIX rules to DIRECT, at the start of prepend | Watt or Steamcommunity_302 |
| Both services are inactive | Deletes the managed rule block | The subscription's Steam rules / Clash |

The watcher edits every configured subscription override file directly. It does
not require Clash to be running. If Clash is already running and restart is
enabled, the script restarts it after a rule change; otherwise the changes apply
the next time Clash starts.

## Detection

- Steamcommunity_302 is active only while steamcommunity_302.cli or
  steamcommunity_302.caddy exists. Merely opening its GUI does not trigger.
- Watt is active only while Steam++.Accelerator owns a configured local
  HTTP/HTTPS listening port. A resident Watt UI does not trigger.
- Defaults: check every three seconds and require two matching checks before
  changing rules.

## Install

1. Configure each Clash Verge Rev subscription with the parent
   desktop/README.md procedure. The templates do not permanently force Steam
   to DIRECT.
2. Copy this folder to a permanent local location.
3. Copy SteamRoutingWatcher.config.example.psd1 to
   SteamRoutingWatcher.config.psd1.
4. Edit the copied configuration:
   - Profiles: absolute paths of every subscription override YAML to switch.
   - ClashExecutable: absolute path of clash-verge.exe. Leave empty if route
     files should update only.
   - RestartRunningClient: true restarts a running client after changes; false
     leaves reloading to the user.
5. Open an elevated PowerShell in this folder and test once:

   ~~~powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\SteamRoutingWatcher.ps1 -Once
   ~~~

6. After confirming the test, create a Task Scheduler task triggered at logon.
   Set Program to wscript.exe and Arguments to the absolute path of
   SteamRoutingWatcher.vbs. The VBS wrapper runs the watcher invisibly, without
   a console window.

## Managed rule block

When an accelerator starts, the watcher writes this at the beginning of each
override's prepend section:

~~~yaml
# BEGIN Steam accelerator routing
- DOMAIN-SUFFIX,steampowered.com,DIRECT
- DOMAIN-SUFFIX,steamcommunity.com,DIRECT
- DOMAIN-SUFFIX,steamstatic.com,DIRECT
- DOMAIN-SUFFIX,steamusercontent.com,DIRECT
- DOMAIN-SUFFIX,steamcontent.com,DIRECT
- DOMAIN-SUFFIX,steam-chat.com,DIRECT
- DOMAIN-SUFFIX,steamserver.net,DIRECT
# END Steam accelerator routing
~~~

When both accelerators stop, it removes only this marked block. Do not edit
lines between the markers manually.

## Logs

By default, SteamRoutingWatcher.log is created beside the script:

- accelerator active: Watt; Steam DIRECT
- accelerator active: Steamcommunity_302; Steam DIRECT
- accelerator active: Watt, Steamcommunity_302; Steam DIRECT
- no accelerator: Steam via Clash subscription rules

If a Watt update changes its listener ports, change WattProxyPorts in the local
configuration. If Steamcommunity_302 changes its process names, update the
matching expression in the script.
