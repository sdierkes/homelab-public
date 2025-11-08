# Proxmox Wake/Shutdown-on-LAN for Containers

In my homelab, I have some containers that I don’t want running all the time. Since I didn’t want to log in every time just to start or stop them — and I wasn’t looking for a more complex API-based solution — I went for a simpler approach: using a WOL (Wake-on-LAN) service running directly on Proxmox to handle it for me.  

With this setup, I can easily start or stop containers from my phone or tablet using any Wake-on-LAN app.  

The scripts use regular WOL packets, but the action depends on the **port** they’re sent to. Depending on the port, the same packet will either **wake up** or **shut down** a container — a little twist on the original idea of WOL. 😄  

## The Scripts

… coming soon

## The Service

… coming soon
