# Omada Network Application in Docker

A self-built Docker image and Compose deployment for the TP-Link Omada Network Application
(controller), built **only** from TP-Link's official `linux_x64` tarball. No third-party Omada
image or layer is used.

- Pinned version: **6.3.0.45** (`Omada_Network_Application_v6.3.0.45_linux_x64.tar.gz`)
- Base: `ubuntu:24.04`, Java 17, MongoDB 8.0, `jsvc` (all required by the tarball's own
  `install.sh` / `bin/control.sh`; see the comment block at the top of the `Dockerfile`)
- Architecture: `linux/amd64` only

## Prerequisites

- A Linux Docker host (Docker Engine + Compose v2), on the **same L2 network** as your Omada devices.
- **x86_64 CPU with AVX.** MongoDB 8.0 will not start without it. Check: `grep -c avx /proc/cpuinfo` (must be > 0).
- **Host networking.** The container runs with `network_mode: host`; device discovery/adoption uses
  L2 broadcast and UDP that do not work through Docker's NAT bridge. The controller's ports are therefore
  bound directly on the host (8088, 8043, 8843, 8044, 19810/udp, 27001/udp, 29810/udp, 29811-29817).
  Host networking is only meaningful on Linux; on Docker Desktop (macOS/Windows) it is the VM's network,
  so the stack runs but LAN discovery and `localhost` access do not work there.
- The official tarball placed at `vendor/Omada_Network_Application_v6.3.0.45_linux_x64.tar.gz`
  (download it from TP-Link's site). The build verifies it against `vendor/SHA256SUMS`.
  TP-Link does not publish a checksum that we know of; the recorded SHA-256 is of the file that was
  downloaded when this project was set up. Compare it against a trusted second download if that matters to you.

## Security: LAN only

**Do not expose the controller to the public Internet.** Because of host networking, every controller
port listens on all host interfaces. Restrict them with a host firewall to your LAN / trusted networks.
Example with `ufw` (adjust the subnet):

```bash
for p in 8088 8043 8843 8044 29811:29817; do sudo ufw allow from 192.168.0.0/16 to any port $p proto tcp; done
for p in 19810 27001 29810; do sudo ufw allow from 192.168.0.0/16 to any port $p proto udp; done
```

Do not publish these ports through a cloud security group open to `0.0.0.0/0`, a port forward, or an
unauthenticated reverse proxy. For remote access use a VPN into the LAN.

## Build

```bash
docker build --platform linux/amd64 --build-arg INSTALL_VER=6.3.0.45 -t omada-controller:6.3.0.45 .
# or: docker compose build
```

`INSTALL_VER` has no default; building without it fails. The image is tagged with the exact version.

## Run

```bash
docker compose up -d --build
docker compose logs -f          # controller, startup and MongoDB logs
docker compose ps               # health: starting -> healthy (first boot takes about 1-5 minutes)
```

Then open `https://<host-ip>:8043` (or `http://<host-ip>:8088`) from a LAN machine and run the setup wizard.
Set `TZ` in your environment (e.g. `TZ=Europe/Berlin docker compose up -d`) to change the time zone.

Behaviour (see `docker-compose.yml`):

- `restart: unless-stopped`: restarts after a crash and after a host reboot.
- `stop_grace_period: 120s`: `docker compose stop/down` runs `control.sh stop`, which shuts down the
  controller and its MongoDB cleanly. A full stop measured ~94 s under x86 emulation; on native
  hardware expect less. Do not lower the timeout.
- `cap_add: DAC_READ_SEARCH, SYS_TTY_CONFIG`: `jsvc` needs them to drop to the unprivileged `omada` user
  (without them: `set_caps(CAPS) failed for user 'omada'`).
- Health check: `GET http://127.0.0.1:8088/actuator/linux/check` must return 200 or 503 (the same readiness
  test as TP-Link's `control.sh`). `--start-period` is 300 s.

### How it runs

`entrypoint.sh` (under `tini`) prepares the volumes, then runs TP-Link's own `bin/control.sh start`, which
launches the controller as a `jsvc` daemon running as user `omada`. The controller starts its own
embedded `mongod` (port 27217, localhost only). The entrypoint tails `startup.log`, `server.log` and
`mongod.log` to `docker logs`, exits non-zero if the daemon dies (so Docker restarts it), and on
`SIGTERM` runs `control.sh stop`.

## Volumes

| Volume (named) | Mount in container | Contents |
|---|---|---|
| `omada-data` | `/opt/tplink/EAPController/data` | controller configuration, embedded MongoDB (`db/`), keystore, in-app auto backups (`autobackup/`), `check-mongo/LAST_MAIN_VERSION.info` |
| `omada-logs` | `/opt/tplink/EAPController/logs` | `server.log`, `startup.log`, `mongod.log` |

Removing and recreating the container keeps all sites, adopted devices, users and settings. To use host
bind mounts instead, replace the volume entries in `docker-compose.yml` (the entrypoint seeds an empty
data directory and fixes ownership to the `omada` user, uid/gid 508).

## Backup and restore

### Filesystem-level (scripts)

```bash
scripts/backup.sh [output-dir]       # default ./backups; stops the controller, archives omada-data, restarts it
docker compose stop                  # the controller must be stopped before a restore
scripts/restore.sh backups/omada-data-<timestamp>.tar.gz   # REPLACES the contents of omada-data
docker compose up -d
```

`backup.sh` briefly stops the controller so MongoDB's files are consistent, and restarts it only if it stopped it.
`restore.sh` refuses to run (non-zero exit, clear error) unless it can confirm the container is stopped, and
validates the archive before touching the volume. Variables `CONTAINER`, `DATA_VOLUME`, `IMAGE` override
the defaults. Copy the archive off the host for real disaster recovery; it can restore onto another host.

### In-app (live, application-consistent)

Omada's own backup does not require stopping the controller. In the web UI (Global View) use
**Settings > Maintenance**. On 6.3.0.45 that page has three sections: **Backup** (choose the contents, then
*Export* to local file, file server or local disk), **Backup Schedule** (automatic backups, listed under
*Backup Files List*) and **Restore** (*Import* from a local file or file server). Use it as a complement to
the scripts. (Menu path confirmed against a running 6.3.0.45 controller.)

## Upgrade

Each controller version is a new, explicitly versioned image tag. Never use `latest`.

1. Back up: `scripts/backup.sh` (and/or an in-app backup).
2. Put the new official tarball in `vendor/`, add its checksum to `vendor/SHA256SUMS`, and update the
   version in `docker-compose.yml` (both `image:` and `build.args.INSTALL_VER`) and in the `scripts/` defaults/`IMAGE` env.
3. Stop the old container: `docker compose down` (waits for a clean shutdown).
4. Build and start the new version: `docker compose up -d --build`
5. Verify: `docker compose ps` shows `healthy`, and
   `docker exec omada-controller /opt/tplink/EAPController/bin/control.sh version` prints the new version.

Notes:
- Do not skip MongoDB major versions. `control.sh` records the last MongoDB major version in
  `data/check-mongo/LAST_MAIN_VERSION.info` and asks interactively (impossible in a container) if it jumps.
- Read TP-Link's release notes first; some versions have their own upgrade prerequisites.

## Rollback

The controller migrates its database on first start of a newer version, and that migration is
**one-directional**. **Starting an older image tag against data that a newer version has already
migrated is unsupported and unsafe. Do not do it.** Roll back by restoring the pre-upgrade backup:

1. `docker compose down`
2. `scripts/restore.sh backups/<pre-upgrade-backup>.tar.gz`
3. Set the compose `image:` / `INSTALL_VER` back to the **prior** pinned version (and rebuild that image if it is no longer present).
4. `docker compose up -d`, then verify health and the reported version as above.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | image build; header comment lists each dependency and the official script line that requires it |
| `docker-compose.yml` | host-networked deployment |
| `entrypoint.sh`, `healthcheck.sh` | container start/stop supervision and readiness probe |
| `scripts/backup.sh`, `scripts/restore.sh` | filesystem-level backup and restore |
| `vendor/` | official tarball (not committed) and `SHA256SUMS` |
