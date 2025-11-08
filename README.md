# Collection of Scripts and Tips for Homelab Servers

This repo includes handy scripts and configs for software commonly used in homelab setups.  

> ⚙️ **Note:**  
> This repository assumes you already have a working homelab or server environment.  
> Some basic experience with the Linux shell is required — you’ll likely need to edit files directly in the shell and make changes under `/etc` or to system services using `systemctl`.

## Wake-on-LAN (and Shutdown) for VMs and LXC Containers in Proxmox

These scripts let you wake up Proxmox VMs and LXC containers using Wake-on-LAN (WoL) packets.  
The same trick is used for shutdown — by sending WoL packets on a different port.
