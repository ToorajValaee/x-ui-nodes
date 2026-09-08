# x-ui-nodes

Automation scripts for preparing 3x-ui nodes with Cloudflare DNS and VLESS REALITY inbound setup.

## What this script does

`scripts/setup-3xui-node.sh` prepares a new node server for a multi-node 3x-ui setup.

It does the following:

1. Asks for the node name, for example `ca1`, `ca2`, `de3`.
2. Asks for the root domain, default `site.com`.
3. Asks for a Cloudflare API token. The token is used only for DNS changes.
4. Creates or updates two DNS records:
   - `<node>.site.com` for client VPN traffic
   - `<node>-panel.site.com` for panel/API access
5. Runs the normal 3x-ui installer.
6. Reads the generated panel port, panel path, and API token from `/etc/x-ui/install-result.env`.
7. Creates a VLESS REALITY inbound on port `443` through the 3x-ui API.
8. Writes node connection details to `/root/<node>-node-info.txt`.

## One-line install

Run as root on a clean server:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ToorajValaee/x-ui-nodes/main/scripts/setup-3xui-node.sh)
```

## Domain model

The script creates two domains per node:

```text
ca1.site.com        = VPN/client address
ca1-panel.site.com  = panel/API address
```

When adding the node to the master panel, use the panel domain:

```text
Address: ca1-panel.site.com
Port: value from /root/ca1-node-info.txt
Base path: value from /root/ca1-node-info.txt
```

Client configs and subscription results should use the VPN domain:

```text
ca1.site.com:443
```

Do not use `ca1-panel.site.com` as the client VPN address.

## During the 3x-ui installer

The script intentionally runs the normal 3x-ui installer, because SSL is handled there.

When the installer asks for SSL/domain, use only the panel domain:

```text
ca1-panel.site.com
```

Do not use the VPN/client domain there:

```text
ca1.site.com
```

Before the SSL step, make sure:

```text
ca1-panel.site.com points to this server IP
Cloudflare proxy is DNS-only, not orange-cloud
Port 80 is open
No other service is using port 80
```

## Cloudflare token

The Cloudflare token is used only to create or update DNS records. It is not used for SSL.

Required permission:

```text
Zone DNS Edit
```

The token should be scoped only to the zone you use, for example `site.com`.

## REALITY defaults

The script creates this inbound:

```text
Protocol: VLESS
Port: 443
Network: TCP/RAW
Security: REALITY
Target/Dest: www.cloudflare.com:443
Server Names/SNI: www.cloudflare.com
Flow: none / empty
```

The generated client settings are written to:

```text
/root/<node>-node-info.txt
```

## Notes

The script supports Debian/Ubuntu with `apt` and RHEL/AlmaLinux-style systems with `dnf` or `yum`.

For multi-node setup, after this script finishes, add the node from your master 3x-ui panel using the values printed in `/root/<node>-node-info.txt`.
