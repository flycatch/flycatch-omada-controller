# Proposal

## Why

The TP-Link Omada Software Controller currently must be installed directly on a host OS (bare metal or VM) using TP-Link's Linux `.tar.gz` package, which couples the controller's Java/MongoDB runtime to the host and makes upgrades, backups, and reproducible deployment difficult. Third-party Docker images exist but are not acceptable here because they are not vendor-reviewable, may lag behind official releases, and carry unverified supply-chain risk. We need a self-maintained Docker image and Compose configuration, built directly from TP-Link's official `Omada_Network_Application_v6.3.0.45_linux_x64.tar.gz` distribution, so the controller can be deployed, upgraded, and operated in a reproducible, documented way on our own infrastructure.

## What Changes

- Add a `Dockerfile` that downloads/uses the official TP-Link Omada Controller `linux_x64` `.tar.gz` (pinned to `6.3.0.45`), installs the runtime dependencies required by that package (Java 17 JRE, MongoDB server, `jsvc` and `curl` — all verified against the `6.3.0.45` package's own `install.sh`/`bin/control.sh`, which require `jsvc` and launch the controller through it), and lays out the controller at the fixed install path `/opt/tplink/EAPController` that the package's scripts assume.
- Add a `docker-compose.yml` that runs the built image using **host networking** (required for Omada L2/broadcast device discovery and adoption on the LAN), mounts named/bind volumes for the controller's data (config + embedded MongoDB database) and logs directories, defines restart policy, and wires in a health check.
- Add an entrypoint script that starts the controller through the package's own `bin/control.sh` (which daemonizes via `jsvc`; the controller in turn launches its own embedded `mongod`), keeps the container in the foreground by monitoring the daemon, forwards `SIGTERM` to `control.sh stop` for a graceful controller/MongoDB shutdown within the stop-timeout window, and streams controller/MongoDB logs to `docker logs` in addition to the persisted logs volume.
- Add a health check script usable by Docker's `HEALTHCHECK` that queries the controller's own readiness endpoint (`/actuator/linux/check` on the HTTP management port, the same one `control.sh` uses) to verify the controller is actually serving.
- Add backup and restore shell scripts that: (a) trigger or capture an Omada backup (consistent with TP-Link's own backup mechanism) and copy/export it outside the container, and (b) restore a prior backup file into a fresh or stopped controller's persistent volume.
- Define a controlled upgrade/rollback strategy: versioned, immutable image tags (e.g., `omada-controller:6.3.0.45`), a documented upgrade procedure (stop → backup → pull/build new tag → start), and a documented rollback procedure (restore pre-upgrade backup into a container running the prior pinned image tag), including the caveat that TP-Link's MongoDB schema upgrades are one-directional and a rollback to an older controller version requires restoring a pre-upgrade backup rather than simply swapping image tags back.
- Add `README.md` documentation covering build/run instructions, volume layout, required host firewall/network posture (LAN-only — management ports must not be exposed to the public Internet), backup/restore usage, and the upgrade/rollback procedure.
- **BREAKING**: N/A — this is a net-new deployment target; it does not modify or replace any existing running system in this repository.

## Capabilities

### New Capabilities
- `omada-controller-image`: Requirements for building a reproducible, version-pinned Docker image from the official TP-Link Omada Controller Linux tarball, including the dependency set (Java, MongoDB, and any other OS packages) that must be installed inside the image, and the health check contract exposed by the image.
- `omada-controller-deployment`: Requirements for running the image via Docker Compose — host networking for device discovery/adoption, persistent volumes for data/database/logs, restart policy, graceful shutdown behavior, and the constraint that management interfaces must never be exposed directly to the public Internet.
- `omada-controller-maintenance`: Requirements for operational maintenance of a running deployment — backup script behavior, restore script behavior, and the versioned upgrade/rollback procedure (including the one-way MongoDB migration caveat).

### Modified Capabilities
<!-- none; greenfield project with no existing specs -->

## Impact

- **New files**: `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `healthcheck.sh`, `scripts/backup.sh`, `scripts/restore.sh`, `README.md`.
- **New runtime dependencies** (inside the image only): a JRE matching what TP-Link's `6.3.0.45` install script requires, MongoDB server pinned to 8.0 (within the 3.0–8.0 range the package supports), `jsvc`/`libcommons-daemon-java`, `curl`, plus supporting OS packages (certificates, privilege-drop tool, tzdata) identified by inspecting the official package's scripts.
- **Network/security posture**: the container must run with `network_mode: host` (or equivalent) on the Docker host, which means the controller's management, portal, and discovery ports (8088, 8043, 8843, 8044, and the 19810/27001/29810/29811-29817 discovery/management range) are bound directly on the host's network interfaces. Host-level firewalling to keep these off the public Internet is part of the deployment contract, not optional guidance.
- **Operational dependencies**: backups rely on the controller's own backup/export mechanism and/or point-in-time copies of the persisted data volume while the container is stopped; restores require the container to be stopped during the restore operation.
- **No impact** on existing code in this repository, since none currently exists — this is the first capability added to the project.
