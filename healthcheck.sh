#!/bin/bash
# Healthy only when the controller's own readiness endpoint answers 200 or 503,
# the same test bin/control.sh (is_in_service) uses. Connection refused => unhealthy.
PROPS=/opt/tplink/EAPController/properties/omada.properties
PORT=$(grep "^[^#;]" "$PROPS" 2>/dev/null | sed -n 's/manage.http.port=\([0-9]\+\)/\1/p' | sed -r 's/\r//')
PORT=${PORT:-8088}

code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:${PORT}/actuator/linux/check")
if [ "$code" = "200" ] || [ "$code" = "503" ]; then
    exit 0
fi
echo "controller not ready (HTTP ${code})" >&2
exit 1
