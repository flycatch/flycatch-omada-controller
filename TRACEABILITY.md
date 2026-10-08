# Spec traceability and verification notes

Environment used for verification: macOS arm64, Docker Desktop, image run as `linux/amd64` under
Rosetta (MongoDB 8.0.32 started fine). Host networking there is the Docker VM's network, so anything
needing a real LAN or a real Linux host is listed as **not verified**.

## omada-controller-image

| Requirement | Satisfied by | Verified |
|---|---|---|
| Built from official TP-Link tarball only | `Dockerfile` (`COPY vendor/...tar.gz`, `sha256sum -c vendor/SHA256SUMS`, extract to `/opt/tplink/EAPController`) | Yes: build log shows checksum OK |
| Version pinned, no "latest" | `ARG INSTALL_VER` without default; `docker-compose.yml`; tag `omada-controller:6.3.0.45` | Yes: blank build fails (tarball `..._v_linux_x64...` not found) |
| Dependencies derived from the package's own scripts | `Dockerfile` header comment (cites `install.sh`/`control.sh` lines); Java 17, MongoDB 8.0, `jsvc`, `libcommons-daemon-java`, `curl` | Yes: `java -version` 17.0.20, `mongod --version` 8.0.32, `jsvc` present |
| JSVC explicitly resolved | `jsvc` required (`install.sh` `jsvc_check`; `control.sh`); included | Yes |
| Health check distinguishes ready from running | `healthcheck.sh` + `HEALTHCHECK` (`/actuator/linux/check`, 200/503) | Yes: observed `unhealthy` (HTTP 000) then `healthy` |

## omada-controller-deployment

| Requirement | Satisfied by | Verified |
|---|---|---|
| Host networking | `docker-compose.yml` `network_mode: host` | Yes on Linux x86_64 (`flycatch-desk-4` / 192.168.0.105). After cutover, `https://192.168.0.105:8043` from another LAN host returns 6.3.0.45 `configured:true` (task 4.1). Device discovery/adoption confirmed by operator on the live site after `.cfg` restore (task 4.2) |
| Persistence across recreate | named volumes `omada-data`, `omada-logs` | Yes: production now uses named volumes on the Linux host; sites/devices present after in-app restore of the 5.15.24.19 `.cfg` |
| Restart on failure / reboot | `restart: unless-stopped`; entrypoint exits non-zero if daemon dies | Failure: yes (killed controller, restart count 1, healthy again). Docker daemon restart: yes (Docker Desktop quit and reopened; container came back on its own with a new start time and reached `healthy`). A full host reboot was not done |
| Graceful shutdown | `stop_grace_period: 120s`, SIGTERM -> `control.sh stop` | Yes: clean exit 0 at ~94 s under emulation, restart with no repair messages. With a 60 s timeout Docker killed the container (JVM shutdown is slow; MongoDB had already closed cleanly) |
| Logs via `docker logs` | `entrypoint.sh` tails `startup.log`, `server.log`, `mongod.log` | Yes |
| Not exposed to the Internet | README "Security: LAN only" section; no public-exposure example anywhere | Documentation only (host firewall is the operator's responsibility) |
| README walkthrough from a clean checkout (task 7.1) | `README.md` Build / Run / Backup and restore | Yes (local Docker Desktop) plus production cutover on 192.168.0.105: official image built on the Linux host, host-network compose, 5.15 left stopped for revert, 6.3.0.45 healthy and configured |

## omada-controller-maintenance

| Requirement | Satisfied by | Verified |
|---|---|---|
| Backup script, exportable | `scripts/backup.sh` | Yes: 6.0 MB timestamped archive on host, container restarted; run against a controller with a configured extra site (`backup-marker-site`). No real device (none available) |
| Restore script, stopped-container only | `scripts/restore.sh` | Yes: refuses while running; restored into a fresh volume, controller booted healthy and the API listed both sites incl. `backup-marker-site` using the original admin login |
| Versioned upgrade procedure | README "Upgrade" | Mechanics yes using a rebuild of the same version (no second version available) |
| Rollback via restore, not tag swap | README "Rollback" (explicitly states tag-swap is unsupported) | Restore sequence yes (post-backup change was reverted). **Not verified** with an actual older version (task 6.2) |

## Discrepancies found vs. original plan (planning artifacts were updated accordingly)

- `jsvc` is required; the controller starts its own `mongod`; entrypoint drives `control.sh`.
- Compose needs `cap_add: DAC_READ_SEARCH, SYS_TTY_CONFIG` for `jsvc` to drop privileges. Now reflected in `design.md`.
- Stop takes longer than the 60 s first planned; grace period is 120 s.
- In-app backup menu path confirmed in the 6.3.0.45 UI: Global View > Settings > Maintenance (Backup / Backup Schedule / Restore); README corrected (it said "Backup & Restore").
