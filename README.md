# Collection of Scripts and Tips for Homelab Servers

This repo includes handy scripts and configs for software commonly used in homelab setups.

## Wake-on-LAN (and Shutdown) for VMs and LXC Containers in Proxmox

These scripts let you wake up Proxmox VMs and LXC containers using Wake-on-LAN (WoL) packets.
The same trick is used for shutdown — by sending WoL packets on a different port.
