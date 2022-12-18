+++
title = "Easily setup Mullvad as an exit node for Tailscale using Docker"
date = 2022-12-18

[taxonomies]
tags = ["tailscale", "mullvad", "vpn", "docker"]
+++

I'm a big fan of [Tailscale](https://tailscale.com). It's a great way to quickly and easily set up a VPN between all of my devices.

My home server is configured to only allow SSH connections over Tailscale, and I wanted a way to have that SSH connection running while also having external traffic be private with the help of [Mullvad's](https://mullvad.net) VPN service.

Docker makes this easy by configuring the tailscale container to share the network stack of the mullvad container.

<!-- more -->

## Setting up the containers

I use docker-compose to define the configuration.
<br/>
These containers can be started by first copying the configuration below into a new `docker-compose.yml` file.
<br/>
Then, run `docker-compose up -d` in the folder containing the docker-compose file.

```yaml
version: "3.9"
services:
  wireguard-mullvad:
    image: ghcr.io/linuxserver/wireguard
    container_name: mullvad-wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=1420
      - PGID=1420
      - TZ=America/New_York
    volumes:
      - /services/mullvad/wireguard:/config:Z # edit path for config files
      - /lib/modules:/lib/modules:ro
    ports:
      - 53000:51820/udp
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
    restart: unless-stopped
    healthcheck:
      test: curl --fail 1.1.1.1 || exit 1
      interval: 10s
      retries: 6
      start_period: 10s
      timeout: 2s

  tailscale-mullvad:
    container_name: tailscale-mullvad
    image: tailscale/tailscale:latest
    volumes:
      - /services/mullvad/tailscale:/var/lib/tailscale # edit path for config files
      - /lib/modules:/lib/modules:ro
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    command: tailscaled --tun=userspace-networking
    restart: unless-stopped
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
    depends_on:
      - wireguard-mullvad
    network_mode: service:wireguard-mullvad
    healthcheck:
      test: wget --no-verbose --tries=1 --spider tailscale.com || exit 1
      interval: 10s
      retries: 6
      start_period: 10s
      timeout: 2s
```

## Configuring Mullvad

A wg0.conf file is needed, you can generate it on [Mullvad's website](https://mullvad.net/en/account/#/wireguard-config).

The wg0.conf file should be placed in the wireguard container at `/config/wg0.conf`. Adjust the path on your system depending on the bind mount path.

Restart the containers with `docker-compose restart`.

## Configuring Tailscale

Log into tailscale and configure it as an exit node with this command.

```bash
docker exec -it tailscale-mullvad-usa tailscale up --hostname=mullvad-usa --advertise-exit-node
```

## Testing the connection

Follow steps 3 & 4 [here](https://tailscale.com/kb/1103/exit-nodes) to finish the exit node setup and connect to the exit node.

Mullvad provides a VPN leak tester [here](https://mullvad.net/en/check).