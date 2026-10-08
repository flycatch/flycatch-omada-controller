# Design

## Context

See `proposal.md` - Why. This is a greenfield project: no existing Dockerfile, compose file, or deployment tooling exists yet. Relevant external constraints:

- TP-Link publishes `Omada_Network_Application_v6.3.0.45_linux_x64.tar.gz` as an official download (confirmed present on TP-Link's download portal alongside the `.deb` and Windows installer for the same `6.3.0.45` build).
- The `6.3.0.45` tarball's own `readme.txt`, `install.sh` and `bin/control.sh` were inspected directly (see Open Questions, now resolved) and establish:
  - `install.sh` copies `bin data properties lib install.sh uninstall.sh` to `/opt/tplink/EAPController` and symlinks the system `mongod` to `bin/mongod`. `control.sh` hardcodes `/opt/tplink/EAPController/data/...` paths (e.g. `XDG_CONFIG_HOME`, `data/check-mongo/LAST_MAIN_VERSION.info`), so the install path is fixed. The archive also ships a `data/` tree (`db`, `html`, `keystore`, `pdf`, `static`, `cluster`) and an empty `logs/`; `work/` and `data/autobackup` are created at start.
  - **`jsvc` is required.** `install.sh` aborts without it and `control.sh` exits with "jsvc not found". The controller is started as `jsvc -home $JRE_HOME -cp /usr/share/java/commons-daemon.jar:lib/*:properties -user $OMADA_USER -pidfile /var/run/omada.pid -outfile/-errfile logs/startup.log com.tplink.smb.omada.starter.OmadaLinuxMain start`; `jsvc` daemonizes, so the app is not the foreground process.
  - **Java 17** is the minimum (`install.sh` rejects anything below 17.0.0; `readme.txt` says "supports Java 17"). No JDK 25 requirement exists for this build.
  - **MongoDB 3.0–8.0** is supported and not bundled. `control.sh` tracks the last-used Mongo main version in `data/check-mongo/LAST_MAIN_VERSION.info` and prompts interactively ("continue launching? y/n") if the version jumps by more than one major release. This change pins MongoDB `8.0` (`mongodb-org-server` from MongoDB's official apt repo; requires AVX).
  - **The controller launches `mongod` itself**: `properties/omada.properties` defines `eap.mongod.*` (port `27217`, `--dbpath ../data/db`, `--logpath ../logs/mongod.log`) and `control.sh` removes `/tmp/mongodb-27217.sock` on stop. No separate `mongod` process management is required in the container.
  - `jsvc` drops to the `omada` user and needs the `DAC_READ_SEARCH` and `SYS_TTY_CONFIG` capabilities, which Docker removes by default (without them: `set_caps(CAPS) failed for user 'omada'`), so the compose service adds both via `cap_add`.
  - `control.sh` runs as root by default; `OMADA_USER` selects another user, but then `data`, `logs` and `work` must be owned by it.
  - `control.sh` also requires `curl` and treats HTTP 200 or 503 from `http://localhost:8088/actuator/linux/check` as "in service".
  - Supporting OS packages: `ca-certificates`, `curl`, `libcommons-daemon-java`, `gosu` (privilege drop), `tzdata`, `gnupg` (MongoDB apt key); font/harfbuzz libraries only if runtime testing shows they are needed (the controller bundles a headless-Chromium/`jvppeteer` report feature).
- Omada device discovery/adoption uses L2 broadcast and UDP discovery protocols (ports such as `19810/udp`, `27001/udp`, `29810/udp`) that do not traverse Docker's default bridge/NAT network cleanly — this is the basis for the host-networking requirement in `omada-controller-deployment`.
- Controller TCP ports: `8088` (HTTP mgmt/portal), `8043` (HTTPS mgmt), `8843` (HTTPS portal), `8044` (dedicated upgrade/ES HTTPS), `29811`-`29817` (device management/adopt/upgrade/transfer/rtty/monitor, by protocol version).

## Goals / Non-Goals

**Goals:**
- Build the image directly from TP-Link's official tarball with no third-party Omada image/layer in the dependency chain.
- Make the exact runtime dependency set (Java version, MongoDB version, OS packages) a verified, documented fact tied to the pinned `6.3.0.45` build, not an assumption carried from unrelated versions.
- Produce a deployment that is operable (observable logs, health check, graceful shutdown, automatic restart) and recoverable (backup/restore, safe upgrade/rollback).

**Non-Goals:**
- Supporting architectures other than `amd64` (ARM support can be a future change if needed).
- Running MongoDB as an external/separate service or container — this design keeps the embedded single-container model (controller + MongoDB in one container) for simplicity, matching how TP-Link's own package is designed to run on a single host.
- Building a general-purpose multi-version image matrix (OpenJ9, beta channels, multi-arch tags) — this change delivers exactly one pinned version, `6.3.0.45`, on `amd64`.
- TLS termination / reverse proxy in front of the controller — out of scope; the controller's own HTTPS ports are used directly within the trusted LAN.

## Decisions

### Base OS image: Ubuntu LTS (24.04)
**Decision**: Use `ubuntu:24.04` as the base image.
**Rationale**: MongoDB 8.0's official apt repository publishes packages for current Ubuntu LTS releases; Ubuntu 24.04 is the current LTS with long security-patch support, and TP-Link's own install guidance for Linux targets Ubuntu/Debian-family systems with apt-based package management, which matches how the dependency installation step (below) needs to work.
**Alternatives considered**: Debian slim (also apt-based and MongoDB-supported, slightly smaller) — viable alternative, deferred only because Ubuntu's broader MongoDB/JDK package availability reduces verification risk for a first implementation. Alpine was rejected because MongoDB's official builds do not target musl libc.

### Dependency installation is script-driven and derived from the actual tarball, not hardcoded from memory
**Decision**: The Dockerfile's dependency-installation step SHALL be implemented by first extracting and reading the `6.3.0.45` tarball's own `install.sh` (and `bin/control.sh` or equivalent) as part of the implementation task, and encoding exactly the packages/versions that script declares — rather than copying a dependency list from documentation about other Omada versions.
**Rationale**: The requirement in `omada-controller-image` explicitly forbids assuming dependency versions from unrelated releases; the Java version requirement in particular has changed between `6.x` patch releases, so guessing would violate that requirement.
**Alternatives considered**: Hardcode the dependency set from this design doc's research now. Rejected — the research here is reasonably strong secondary evidence but is not a substitute for ground-truth inspection of the pinned tarball, and the spec explicitly requires that inspection.

### Single container runs both MongoDB and the controller process
**Decision**: The Omada controller and its embedded `mongod` run inside the same container, matching the distribution model TP-Link ships (a single host running both). The entrypoint supervises the controller daemon only; the controller itself starts and stops its own `mongod`.
**Rationale**: Matches Non-Goals above; avoids introducing a second service/container and the added complexity of network-based MongoDB auth/configuration for a controller that was never designed to run with district-separated components in the general case.
**Alternatives considered**: Separate MongoDB container/service. Rejected for this change's scope — adds operational complexity (service discovery, startup ordering, network security between containers) without a corresponding requirement in the proposal; can be revisited in a future change if there's a concrete need (e.g., externalizing MongoDB for backup tooling or HA).

### Entrypoint drives the package's own `control.sh` and stays in the foreground
**Decision**: The entrypoint (run under `tini` as PID 1) (1) creates/chowns `data`, `logs` and `work` for the `omada` user and sets `OMADA_USER=omada`, (2) seeds `data/check-mongo/LAST_MAIN_VERSION.info` when absent so `control.sh`'s interactive Mongo-version prompt cannot block, (3) runs `bin/control.sh start` (which daemonizes the controller via `jsvc`), (4) tails `logs/` (including `startup.log`, `server.log` and `mongod.log`) to stdout, and (5) stays alive by polling the daemon (`/var/run/omada.pid`), exiting non-zero if it dies so Docker's restart policy applies. On `SIGTERM` it runs `bin/control.sh stop` (the controller stops its own `mongod`; `control.sh` waits up to 30s before `pkill`) and then exits.
**Rationale**: Directly implements the `omada-controller-deployment` graceful-shutdown requirement using the vendor's own start/stop logic, avoiding MongoDB corruption from an unclean kill. Reusing `control.sh` avoids re-implementing the `jsvc` invocation and JVM options.
**Alternatives considered**: Starting `mongod` ourselves and exec'ing the JVM directly (the original design) — rejected, because the controller manages `mongod` itself and `control.sh`/`jsvc` is the vendor's supported startup path. An init system like `s6-overlay` — unnecessary for one managed daemon; `tini` alone is enough for zombie reaping and signal forwarding.

### Health check targets the controller's HTTPS management port, not just process liveness
**Decision**: `healthcheck.sh` performs an HTTP request against the controller's own readiness endpoint, `http://127.0.0.1:8088/actuator/linux/check` (the port is read from `omada.properties` `manage.http.port`, default 8088), and considers the container healthy only when it returns HTTP 200 or 503, matching the semantics of `control.sh`'s `is_in_service`. The `HEALTHCHECK --start-period` must cover first-boot database initialization (observed to take minutes, not seconds, for embedded MongoDB + first-run schema setup).
**Rationale**: Matches the `omada-controller-image` requirement to distinguish "container running" from "controller actually serving requests"; a plain process-liveness or port-open check would report healthy before the controller can actually serve the UI/API.
**Alternatives considered**: TCP-connect-only check, or an HTTPS check of `:8043/`. Rejected — the port can be open while the Java application is still initializing, and the vendor already provides a purpose-built readiness endpoint.

### Backup/restore scripts wrap the persisted data directory, stopped-container snapshot style
**Decision**: `scripts/backup.sh` requires (or itself performs) a clean stop of the controller container, then archives the persisted data volume's contents (configuration + embedded database files) to a timestamped archive on the host; `scripts/restore.sh` requires the container to be stopped, clears/replaces the data volume's contents with the archive's contents, and the operator restarts the container. Operators are also documented to use Omada's own in-app "Auto Backup"/manual backup feature (which produces an application-level `.cfg` backup file) as a complementary, application-consistent backup mechanism that does not require stopping the container.
**Rationale**: A stop-then-snapshot approach is the only mechanism guaranteed to be consistent for the embedded MongoDB without adding a MongoDB-aware backup tool (e.g., `mongodump` orchestration) that the proposal did not scope; it directly satisfies the "restore requires the controller to be stopped" scenario in `omada-controller-maintenance`. Surfacing the in-app backup as a complement (not a replacement) gives operators a live, application-consistent backup option alongside the filesystem-level one.
**Alternatives considered**: `mongodump`/`mongorestore`-based backup while running. More complex to implement correctly against the embedded instance's auth/socket configuration and not necessary to satisfy the proposal's scenarios; can be a future enhancement.

### Upgrades are a stop/backup/replace-image/start procedure; rollback is backup-restore based
**Decision**: Document and script (where reasonable) the sequence: take a backup → `docker compose down` (or stop with adequate timeout) → update the compose file's image tag to the new pinned version → `docker compose up -d` → verify the controller reports the new version and is healthy. For rollback, explicitly document that reusing the old image tag against already-migrated data is unsupported, and instead: stop the upgraded container → restore the pre-upgrade backup into the data volume → start a container using the prior pinned image tag.
**Rationale**: Matches `omada-controller-maintenance` requirements directly; MongoDB schema migrations performed by the newer controller version on first boot are one-directional, so there is no safe way to "undo" them by simply swapping the image tag back without restoring older data.
**Alternatives considered**: Attempting an automated rollback script that also reverses a MongoDB upgrade. Rejected — out of scope and significantly more complex/risky than restore-from-backup; the mbentley community project's own documentation confirms major-version MongoDB upgrades (e.g., v5→v6) are handled as a distinct, manual, one-directional migration step for the same underlying reason.

## Risks / Trade-offs

- **[Risk]** (Resolved) The Java/MongoDB/`jsvc` requirements were originally assumed from third-party research. → **Mitigation**: They were verified from the `6.3.0.45` tarball itself (Java 17, MongoDB 3.0–8.0, `jsvc` required); the Dockerfile cites those script lines.
- **[Risk]** `jsvc` daemonizes, so the container's main process is the entrypoint, not the controller; a crashed daemon could go unnoticed. → **Mitigation**: the entrypoint polls the daemon pid and exits non-zero on death, and the health check verifies the readiness endpoint.
- **[Risk]** `control.sh` blocks on an interactive prompt if the stored Mongo main version differs non-sequentially from the installed one. → **Mitigation**: the entrypoint seeds/maintains `LAST_MAIN_VERSION.info`, and the upgrade docs forbid skipping MongoDB major versions.
- **[Risk]** The build host used for development may be arm64 (e.g. Apple Silicon); the image is `linux/amd64` only and MongoDB 8.0 needs AVX, which emulation may not provide. → **Mitigation**: runtime verification tasks that cannot run under emulation are completed on an x86_64 Linux host with AVX and recorded in the README's verification notes.
- **[Risk]** Host networking means the controller's ports are bound directly on the Docker host's interfaces, with no Docker-level network isolation. → **Mitigation**: `omada-controller-deployment` makes host firewalling to LAN/trusted-network-only a required part of the deployment contract, and the README must document this explicitly as a prerequisite, not an afterthought.
- **[Risk]** MongoDB 8.0 requires AVX CPU support; older hardware (some older NAS devices, older virtualization hosts, or certain cloud VM types) may not support it, causing `mongod` to crash-loop. → **Mitigation**: README documents the AVX requirement as a prerequisite and the implementation tasks include adding a preflight CPU-feature check (or documenting how to verify it) before deployment.
- **[Risk]** Single-container design (controller + MongoDB) means a MongoDB crash takes down the whole container's health, and vice versa. → **Mitigation**: Accepted trade-off per Non-Goals; the health check and restart policy treat the container as a single unit, consistent with how TP-Link's own package is designed to run on one host.
- **[Trade-off]** Filesystem-snapshot backup requires stopping the container, causing brief downtime for a backup. → **Mitigation**: Documented as the baseline mechanism per `omada-controller-maintenance`; operators are also pointed to Omada's own in-app backup feature for a no-downtime, application-consistent alternative.

## Migration Plan

Not applicable as a data/schema migration (greenfield project, no existing deployment to migrate from). The "migration" in the operational sense (upgrading between controller versions over time) is covered under Decisions → "Upgrades are a stop/backup/replace-image/start procedure" and specified in `omada-controller-maintenance`.

## Open Questions

- **Exact Java version required for `6.3.0.45`** — RESOLVED: Java 17 minimum (`install.sh` `java_version_check`, `readme.txt`). Pin `openjdk-17-jre-headless`.
- **Whether `jsvc` is referenced anywhere in the `6.3.0.45` package's scripts** — RESOLVED: yes, required (`install.sh` `jsvc_check`, `control.sh` `JSVC=$(command -v jsvc)`). The image includes `jsvc` and `libcommons-daemon-java`.
- **MongoDB version** — RESOLVED by decision: pin `8.0` (supported range 3.0–8.0), matching the original design; AVX is a documented prerequisite.
