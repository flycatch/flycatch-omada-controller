# Spec Delta

## Purpose

Defines the operational contract for backing up, restoring, upgrading, and rolling back a containerized Omada Controller deployment so that data loss and broken upgrades are avoidable and recoverable.

## ADDED Requirements

### Requirement: Backup script produces a restorable, exportable backup
A backup script SHALL be provided that produces a backup of the controller's persistent data (configuration and database) and places it outside the container's writable layer (e.g., on the Docker host filesystem), such that the backup can be used to restore the controller to the backed-up state, including onto a different host.

#### Scenario: Running the backup script
- **WHEN** an operator runs the provided backup script against a running (or cleanly stopped) controller deployment
- **THEN** a backup artifact is written to a host-accessible location outside the container, and that artifact contains enough information to fully restore the controller's configuration, sites, and adopted-device state

### Requirement: Restore script returns the controller to a prior backed-up state
A restore script SHALL be provided that, given a backup artifact produced by the backup script (or a native Omada backup file), restores the controller's persistent data such that the controller comes back online with the configuration, sites, and adopted-device state captured at backup time.

#### Scenario: Restoring onto a fresh deployment
- **WHEN** an operator runs the restore script with a valid backup artifact against a newly initialized (empty) controller deployment
- **THEN** the controller starts up and reflects the sites, devices, and settings from the backup, rather than starting as a blank/new controller

#### Scenario: Restore requires the controller to be stopped
- **WHEN** the restore script is invoked
- **THEN** it SHALL ensure the controller container/process is stopped before modifying the persistent data directory, and SHALL fail with a clear error rather than corrupting data if it cannot safely do so

### Requirement: Upgrades use versioned, immutable image tags with a documented procedure
Upgrading the controller SHALL be performed by building/pulling a new, explicitly versioned image tag and replacing the running container, following a documented procedure: take a backup, stop the current container, start a container from the new version-tagged image against the same persistent volumes, and verify the controller starts successfully and reports the expected new version.

#### Scenario: Performing a documented upgrade
- **WHEN** an operator follows the documented upgrade procedure to move from one pinned Omada Controller version to a newer one
- **THEN** a backup was taken before the upgrade, the new container uses a distinct version-tagged image, and the controller comes up running the new version against the pre-existing persistent data

### Requirement: Rollback procedure accounts for one-way database migrations
The documented rollback procedure SHALL make explicit that Omada Controller's embedded database schema migrations are one-directional: simply restarting a container from an older image tag against data that has already been upgraded is not a supported or safe rollback path. The documented rollback procedure SHALL instead rely on restoring the pre-upgrade backup into a container running the prior (older) pinned image tag.

#### Scenario: Rolling back after a failed upgrade
- **WHEN** an upgrade to a newer controller version fails validation and an operator needs to roll back
- **THEN** the operator stops the upgraded container, starts a container using the prior pinned image tag, and restores the pre-upgrade backup into that container's persistent volume — rather than attempting to reuse the already-upgraded data directory with the old image

#### Scenario: Attempting an unsupported same-data rollback
- **WHEN** the documentation is consulted about whether an older image tag can simply be restarted against data already migrated by a newer version
- **THEN** the documentation explicitly states this is unsupported and describes the backup-restore-based rollback path instead
