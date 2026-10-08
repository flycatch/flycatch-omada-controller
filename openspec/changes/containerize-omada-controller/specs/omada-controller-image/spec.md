# Spec Delta

## Purpose

Defines the build-time contract for a self-maintained Docker image that packages the official TP-Link Omada Software Controller Linux distribution, pinned to a specific vendor version, with all runtime dependencies that distribution requires.

## ADDED Requirements

### Requirement: Image is built from the official TP-Link distribution
The image build process SHALL obtain the Omada Controller application files only from TP-Link's officially published Linux `.tar.gz` distribution for the target version. The build SHALL NOT use any third-party-repackaged Omada controller image, layer, or binary as its source of the controller application.

#### Scenario: Building the image
- **WHEN** the Docker image is built
- **THEN** the resulting image's controller files (the `bin`, `data`, `lib`, and `properties` directories under the controller install path) are extracted from the official TP-Link `linux_x64` `.tar.gz` package for the pinned version, and no other Omada controller distribution channel was used

### Requirement: Controller version is explicitly pinned
The image build configuration SHALL pin the Omada Controller version to an exact, explicit version string. The initial pinned version SHALL be `6.3.0.45`. Building without specifying a version, or resolving to a "latest"/"stable" moving target, SHALL NOT be supported.

#### Scenario: Default build uses the pinned version
- **WHEN** the image is built without overriding the version argument
- **THEN** the image contains Omada Controller version `6.3.0.45` and the image is tagged with that exact version (e.g., `omada-controller:6.3.0.45`)

#### Scenario: Attempting to build without a version
- **WHEN** the build is invoked in a way that omits the required version argument/default
- **THEN** the build SHALL fail rather than silently falling back to an unpinned or "latest" package

### Requirement: Required runtime dependencies are installed based on the official package's own install instructions
The image SHALL install exactly the OS-level runtime dependencies that the official TP-Link package's bundled install script (or equivalent official installation documentation) declares as required for the pinned version — including the correct Java runtime version, the database engine (MongoDB) at the version/edition required for that controller release, and any other packages (e.g., certificate authorities, archive utilities, service-management utilities such as JSVC if the official package actually invokes it for this version) that the official install script installs or requires. Dependency versions SHALL NOT be assumed from unrelated or newer Omada Controller releases without verifying them against the pinned version's own install script/documentation.

#### Scenario: Dependency set matches the pinned version's install script
- **WHEN** the image's dependency installation step is inspected
- **THEN** every OS package and runtime (Java, MongoDB, and any others) it installs can be traced back to a requirement documented or scripted by the official `6.3.0.45` package itself

#### Scenario: JSVC requirement is explicitly resolved, not assumed
- **WHEN** determining whether the Apache Commons Daemon (`jsvc`) is required to run the controller process for the pinned version
- **THEN** the determination SHALL be based on inspecting the pinned version's bundled install/start scripts (not on assumptions carried over from older Omada Controller releases). For `6.3.0.45`, `install.sh` and `bin/control.sh` both require `jsvc` (and `control.sh` launches the controller via `jsvc … com.tplink.smb.omada.starter.OmadaLinuxMain`), so the image SHALL include `jsvc`, `libcommons-daemon-java` (providing `/usr/share/java/commons-daemon.jar`), Java 17 or newer, and `curl`

### Requirement: Image exposes a health check
The image SHALL define a container health check that verifies the Omada Controller's management web interface is reachable and responding, distinguishing "container running" from "controller actually serving requests."

#### Scenario: Controller is healthy
- **WHEN** the controller process has fully started and its readiness endpoint (`/actuator/linux/check` on the HTTP management port) returns HTTP 200 or 503, matching the readiness check in the package's own `control.sh`
- **THEN** the image's health check reports the container as healthy

#### Scenario: Controller has not finished starting
- **WHEN** the container has just started and the controller/database are still initializing
- **THEN** the health check reports the container as unhealthy (or starting), for example because the endpoint refuses connections, rather than falsely reporting healthy
