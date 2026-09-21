# NixOS Host States

This file tracks the current state of all NixOS hosts in the infrastructure, including their NixOS version, last verification date, last rebuild date, and OCI container status. This helps identify which hosts need updates or maintenance.

Last updated: 2026-09-20

## Host Status Table

| Host Name | NixOS Version | Last Verified | Last Rebuild | Containers | Notes |
|-----------|---------------|---------------|--------------|------------|-------|
| ali-book | 25.11 (Xantusia) | 2026-09-20 | 2026-09-10 | None | Upgraded to 25.11 |
| audiobookshelf | 25.11 (Xantusia) | 2026-09-20 | 2026-03-11 | **audiobookshelf**: 2.32.1 ⚠️ | Upgraded to 25.11 |
| bifrost | 26.05.20260827.d57af92 | 2026-09-20 | 2026-09-08 | None | Unknown version |
| emma-book | 25.11 (Xantusia) | 2026-08-29 | 2016-01-15 | None | Upgraded to 25.11 |
| endurain | 25.11 (Xantusia) | 2026-09-20 | 2026-06-05 | **endurain**: v0.17.7 ✓ | Upgraded to 25.11 |
| forgejo | lxc-proxmox-26.05.20260910.d58a46e | 2026-09-20 | 2026-09-18 | None | Unknown version |
| frigate | lxc-proxmox-26.05.20260910.d58a46e | 2026-09-20 | 2026-09-18 | **frigate**: 0.17.2 ⚠️ | Unknown version |
| grist | 25.11 (Xantusia) | 2026-03-31 | 2025-12-10 | **grist**: latest ⚠️ | Upgraded to 25.11 |
| hermes | lxc-proxmox-26.05.20260910.d58a46e | 2026-09-20 | 2026-09-16 | None | Unknown version |
| homepage | lxc-proxmox-26.05.20260717.293d6ab | 2026-09-20 | 2026-08-21 | None | Unknown version |
| jellyfin | lxc-proxmox-26.05.20260717.293d6ab | 2026-09-20 | 2026-08-10 | None | Unknown version |
| karakeep | lxc-proxmox-26.05.20260704.a50de1b | 2026-09-20 | 2026-07-13 | None | Unknown version |
| local-proxy | lxc-proxmox-26.05.20260820.5880666 | 2026-09-20 | 2026-08-26 | None | Unknown version |
| mattermost | lxc-proxmox-26.05.20260704.a50de1b | 2026-09-20 | 2026-07-09 | None | Unknown version |
| mealie | 25.11 (Xantusia) | 2026-09-20 | 2026-06-05 | None | Upgraded to 25.11 |
| moltbot | 25.11 (Xantusia) | 2026-02-03 | 2026-01-30 | None | Upgraded to 25.11 |
| murdock | 26.05.20260827.d57af92 | 2026-09-19 | 2026-09-15 | None | Unknown version |
| netalertx | 25.11 (Xantusia) | 2026-07-06 | 2026-07-05 | **netalertx**: 25.11 ⚠️ | Upgraded to 25.11 |
| nextcloud | lxc-proxmox-26.05.20260827.d57af92 | 2026-09-20 | 2026-09-08 | None | Unknown version |
| nix-fury | lxc-proxmox-26.05.20260717.293d6ab | 2026-09-20 | 2026-08-07 | **myspeed**: latest ✓ | Unknown version |
| obsidian | 25.11 (Xantusia) | 2026-07-08 | 2026-06-05 | None | Upgraded to 25.11 |
| ollama | 25.11 (Xantusia) | 2026-09-04 | 2026-05-23 | None | Upgraded to 25.11 |
| omada | 25.11 (Xantusia) | 2026-09-20 | 2026-08-07 | **omada-controller**: 6.0.0.25 ⚠️ | Upgraded to 25.11 |
| omnitools | 25.11 (Xantusia) | 2026-02-15 | 2025-12-10 | **omni-tools**: 0.6.0 ✓ | Upgraded to 25.11 |
| openclaw | 25.11 (Xantusia) | 2026-05-23 | 2026-04-30 | None | Upgraded to 25.11 |
| paperless-ngx | 25.11 (Xantusia) | 2026-09-20 | 2026-06-05 | **paperless-ai**: latest ⚠️ | Upgraded to 25.11 |
| plasma-vm-nixos | 25.11 (Xantusia) | 2026-05-14 | 2026-05-12 | None | Upgraded to 25.11 |
| pocket-id | lxc-proxmox-26.05.20260704.a50de1b | 2026-09-20 | 2026-07-13 | None | Unknown version |
| searxng | lxc-proxmox-26.05.20260827.d57af92 | 2026-09-14 | 2026-08-31 | None | Unknown version |
| tesseract | 25.11 (Xantusia) | 2026-05-22 | 2026-05-22 | None | Upgraded to 25.11 |
| wallabag | 25.11 (Xantusia) | 2026-07-14 | 2026-06-05 | **wallabag**: 2.6.14 ✓ | Upgraded to 25.11 |
| yondu | lxc-proxmox-26.05.20260630.95ca1e2 | 2026-09-20 | 2026-07-02 | **flaresolverr**: latest ⚠️<br>**unpackerr**: latest ⚠️<br>**pinchflat**: latest ✓<br>**transmission_novpn**: 4.0.5 ⚠️<br>**gluetun**: latest ⚠️<br>**jackett**: latest ⚠️<br>**sonarr**: latest ⚠️<br>**prowlarr**: latest ⚠️<br>**radarr**: latest ⚠️<br>**qbittorrent**: latest ⚠️<br>**youtarr**: latest ⚠️<br>**bazarr**: latest ⚠️<br>**dispatcharr**: latest ⚠️ | Unknown version |

## Development/Special Hosts (Not Tracked)

- **nixbook-installer** - Installation media, not a running system
- **nxc-base** - Base container template
- **lxc-tailscale** - Tailscale container template
- **immich** - Development host
- **erpnext** - Development host
- **pocket-id** - Development host
- **onlyoffice** - Development host

## Summary

Statistics are calculated from online hosts only.

## Upgrade Priority

1. High priority services: nextcloud, forgejo, jellyfin
2. Infrastructure: bifrost, local-proxy, homepage
3. Applications: grist, endurain, omnitools, yondu
4. Laptops: emma-book (when online)
