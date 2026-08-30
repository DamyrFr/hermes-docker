#!/bin/sh
# Container healthcheck.
#
# The dashboard is the only thing in this image that reliably answers on a
# socket, so it is what gets probed. Basic auth means the probe gets a 401 --
# which is a perfectly good liveness signal, so `curl -f` is deliberately not
# used: any HTTP response proves the gateway is up and serving.
#
# When the dashboard is switched off there is nothing to probe, and reporting
# `unhealthy` forever would be worse than reporting nothing.
set -eu

if [ "${HERMES_DASHBOARD:-0}" != "1" ]; then
    exit 0
fi

port="${HERMES_DASHBOARD_PORT:-9119}"

# Loopback rather than HERMES_DASHBOARD_HOST: the healthcheck runs inside the
# container's own netns, and 0.0.0.0 is not a valid destination address.
curl --silent --show-error --output /dev/null --max-time 4 \
    "http://127.0.0.1:${port}/" || exit 1
