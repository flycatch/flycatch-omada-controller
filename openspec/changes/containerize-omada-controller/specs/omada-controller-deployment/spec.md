# Spec Delta

## Purpose

Defines how the Omada Controller container must be run (networking, persistence, lifecycle) so that device discovery/adoption works on the LAN, data survives restarts and upgrades, and the deployment never exposes management interfaces to the public Internet.

## ADDED Requirements

### Requirement: Container runs with host networking
The deployment configuration (Docker Compose) SHALL run the Omada Controller container using the Docker host's network namespace (host networking mode) rather than an isolated bridge network with port mapping, because Omada device discovery and adoption rely on L2 broadcast/multicast behavior that does not traverse Docker's default NAT'd bridge network reliably.

#### Scenario: Default compose configuration
- **WHEN** the provided `docker-compose.yml` is used without modification
- **THEN** the controller container is started with host networking enabled, and Omada devices on the same LAN as the Docker host can discover and be adopted by the controller without additional per-device configuration

### Requirement: Controller configuration, database, and logs persist across container restarts
The deployment SHALL mount persistent volumes (named Docker volumes or host bind mounts) for: (a) the controller's configuration and embedded database data directory, and (b) the controller's log directory. Removing and recreating the container SHALL NOT lose configuration, adopted-device state, or historical data stored in these locations.

#### Scenario: Container is recreated
- **WHEN** the controller container is stopped, removed, and a new container is started from the same image using the same volume mounts
- **THEN** all previously configured sites, adopted devices, users, and settings are present in the new container, and prior logs remain accessible in the mounted logs location

### Requirement: Container restarts automatically on failure or host reboot
The deployment configuration SHALL set a restart policy that automatically restarts the controller container after an unexpected exit or after the Docker host reboots, without requiring manual intervention.

#### Scenario: Controller process crashes
- **WHEN** the Omada Controller process inside the container exits unexpectedly
- **THEN** Docker restarts the container automatically according to the configured restart policy

#### Scenario: Docker host reboots
- **WHEN** the Docker host is rebooted and the Docker daemon starts back up
- **THEN** the controller container is started automatically without manual action

### Requirement: Container shuts down gracefully
The deployment SHALL allow enough time, on `docker stop`/`docker compose down`, for the controller application and its embedded database to perform a clean shutdown (flushing and closing the database) before the container is forcibly killed. The default Docker stop timeout SHALL be overridden to a value sufficient for a clean database shutdown.

#### Scenario: Normal stop
- **WHEN** an operator runs `docker compose down` or `docker stop` against the running controller container
- **THEN** the controller and its embedded database are given a stop grace period long enough to shut down cleanly, and the persisted data directory is left in a consistent (non-corrupted) state

### Requirement: Controller and database logs are accessible via standard Docker logging
The deployment SHALL make the controller's (and embedded database's) operational logs retrievable through `docker logs`/the configured Docker logging driver, in addition to any logs written to the persisted logs volume, so operators do not need to exec into the container to diagnose issues.

#### Scenario: Operator checks logs
- **WHEN** an operator runs `docker compose logs` (or `docker logs`) against the running controller container
- **THEN** controller startup, runtime, and error messages are visible in the command output

### Requirement: Management interfaces are not exposed to the public Internet
The deployment documentation and default configuration SHALL NOT include any instruction, example, or default that exposes the controller's management, portal, or device-adoption ports directly to the public Internet (e.g., via a public-facing reverse proxy without access control, or a cloud provider security group open to `0.0.0.0/0`). Because host networking binds these ports on the host's interfaces directly, host-level firewalling restricting access to the LAN/trusted networks is a required part of the deployment, not optional guidance.

#### Scenario: Following the documented deployment steps
- **WHEN** an operator follows the README's deployment instructions as written, with no additional unguided changes
- **THEN** the controller's management (8043/8088), portal (8843), upgrade (8044), and discovery/management (19810, 27001, 29810-29817) ports are reachable only from the local LAN/trusted network, not from the public Internet
