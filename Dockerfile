# syntax=docker/dockerfile:1
#
# Omada Network Application image, built only from TP-Link's official linux_x64 tarball.
#
# Dependency note (task 1.2/1.3) - every package below traces to the 6.3.0.45 package itself
# (install.sh / bin/control.sh / readme.txt inside the tarball):
#   Java 17        install.sh java_version_check (l.208-219) rejects java < 17.0.0; readme.txt
#                  "supports Java 17 and MongoDB 3.0-8.0 ... no built-in JRE and MongoDB".
#   MongoDB        not bundled; install.sh l.305 symlinks the system `mongod` to bin/mongod;
#                  control.sh VALID_VERSIONS (l.36) allows 3.0..8.0. Pinned here to 8.0 (needs AVX).
#                  The controller starts mongod itself (properties/omada.properties eap.mongod.*).
#   jsvc           REQUIRED: install.sh jsvc_check (l.221, called l.256) aborts without it;
#                  control.sh l.168 `JSVC=$(command -v jsvc)` exits if missing and starts the
#                  app via `${JSVC} ${JSVC_OPTS} ${MAIN_CLASS} start`.
#   commons-daemon control.sh l.238: -cp /usr/share/java/commons-daemon.jar (libcommons-daemon-java).
#   curl           control.sh l.175 requires it; l.216 uses it for /actuator/linux/check.
#   install path   install.sh l.5 / l.272: copies bin data properties lib install.sh uninstall.sh
#                  to /opt/tplink/EAPController (control.sh hardcodes /opt/tplink/EAPController/data).
# Other packages (not demanded by the scripts): ca-certificates, gnupg (MongoDB apt key), gosu
# (privilege drop), tini (PID 1), tzdata, procps (pgrep/pkill used by control.sh).

FROM ubuntu:24.04

# Pinned vendor version. Deliberately has NO default: building without it must fail.
ARG INSTALL_VER
ARG MONGO_VER=8.0

ENV DEBIAN_FRONTEND=noninteractive \
    OMADA_HOME=/opt/tplink/EAPController \
    OMADA_USER=omada

RUN test -n "${INSTALL_VER}" || { echo "ERROR: build arg INSTALL_VER is required (e.g. --build-arg INSTALL_VER=6.3.0.45)" >&2; exit 1; } \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg gosu tini tzdata procps \
        openjdk-17-jre-headless jsvc libcommons-daemon-java \
 && curl -fsSL "https://pgp.mongodb.com/server-${MONGO_VER}.asc" \
        | gpg --dearmor -o "/usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg" \
 && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VER}.gpg] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/${MONGO_VER} multiverse" \
        > "/etc/apt/sources.list.d/mongodb-org-${MONGO_VER}.list" \
 && apt-get update \
 && apt-get install -y --no-install-recommends mongodb-org-server \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -r -g 508 omada && useradd -r -u 508 -g omada -d "${OMADA_HOME}" -s /usr/sbin/nologin omada

# Official tarball only (verified against vendor/SHA256SUMS), extracted to the fixed install path.
COPY vendor/SHA256SUMS /tmp/SHA256SUMS
COPY vendor/Omada_Network_Application_v${INSTALL_VER}_linux_x64.tar.gz /tmp/
RUN cd /tmp \
 && grep "Omada_Network_Application_v${INSTALL_VER}_linux_x64.tar.gz" SHA256SUMS | sha256sum -c - \
 && tar -xzf "Omada_Network_Application_v${INSTALL_VER}_linux_x64.tar.gz" \
 && mkdir -p "${OMADA_HOME}" \
 && cd "Omada_Network_Application_v${INSTALL_VER}_linux_x64" \
 && cp -r bin data properties lib install.sh uninstall.sh "${OMADA_HOME}/" \
 && ln -sf "$(which mongod)" "${OMADA_HOME}/bin/mongod" \
 && chmod 755 "${OMADA_HOME}"/bin/* \
 && mkdir -p "${OMADA_HOME}/logs" "${OMADA_HOME}/work" \
 && cp -a "${OMADA_HOME}/data" /opt/omada-data-skel \
 && chown -R omada:omada "${OMADA_HOME}" \
 && rm -rf /tmp/Omada_Network_Application_* /tmp/SHA256SUMS

COPY entrypoint.sh healthcheck.sh /
RUN chmod 755 /entrypoint.sh /healthcheck.sh

LABEL org.opencontainers.image.title="omada-controller" \
      org.opencontainers.image.version="${INSTALL_VER}"

# Persistent state: configuration + embedded MongoDB data, and logs.
VOLUME ["/opt/tplink/EAPController/data", "/opt/tplink/EAPController/logs"]

# TCP: 8088 http mgmt/portal, 8043 https mgmt, 8843 https portal, 8044 upgrade, 29811-29817 device mgmt
# UDP: 19810, 27001, 29810 discovery (the container is run with host networking)
EXPOSE 8088 8043 8843 8044 29811-29817 19810/udp 27001/udp 29810/udp

# First boot (DB init) takes minutes; adjust after timing on target hardware.
HEALTHCHECK --interval=30s --timeout=15s --start-period=300s --retries=3 CMD ["/healthcheck.sh"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
