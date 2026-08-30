# syntax=docker/dockerfile:1.7
#
# ─────────────────────────────────────────────────────────────
# Hermes agent: rtk-instrumented and hardened.
#
# Three things sit on top of the upstream image:
#   1. rtk (github.com/rtk-ai/rtk) -- pinned, checksum-verified -- plus PATH
#      shims that route selected commands through it, because Hermes has no
#      PreToolUse hook to rewrite commands the way Claude Code does.
#   2. The agent's extra Python packages, version-pinned.
#   3. Build-time attack-surface reduction: setuid/setgid bits stripped.
#
# What is deliberately NOT here: capabilities, no-new-privileges, pids limits,
# read-only rootfs. An image cannot drop its own privileges -- those live in
# compose.yaml, and an image built from this file but run without that compose
# file is not the hardened thing.
# ─────────────────────────────────────────────────────────────

# Pinned to the multi-arch index digest, not :latest. `docker build --pull`
# against a floating tag silently changes the base under you; a digest makes
# the build reproducible and turns a base bump into a reviewable diff.
# Refresh with `make base-digest`.
# Registry spelled out rather than left as a short name: Docker would infer
# docker.io, but Podman refuses to guess, and an explicit registry is one fewer
# thing a search-registry setting can redirect.
ARG HERMES_BASE=docker.io/nousresearch/hermes-agent
ARG HERMES_BASE_DIGEST=sha256:7515a2c7448ec9c8ae0b87ce155ece15e1b2b5a24e7416e7f4d50f84b31f5fe6

FROM ${HERMES_BASE}@${HERMES_BASE_DIGEST}

# Upstream's entrypoint starts s6-overlay as root PID 1 and drops to UID 10000
# itself. Pinning a USER at the end of this file would break that, so every
# layer below runs as root and the image stays root-entrypointed on purpose.
USER root

# pipefail so a failure on the left of a pipe fails the build instead of being
# masked by a successful tail.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ── rtk ──────────────────────────────────────────────────────
ARG RTK_VERSION=0.46.0
# Set by buildx; install-rtk.sh falls back to dpkg when building without it.
ARG TARGETARCH

COPY --chmod=0755 scripts/install-rtk.sh /tmp/install-rtk.sh
RUN RTK_VERSION="${RTK_VERSION}" TARGETARCH="${TARGETARCH}" \
      /tmp/install-rtk.sh \
    && rm -f /tmp/install-rtk.sh

# ── Extra Python packages ────────────────────────────────────
# Installed into the agent's own virtualenv. That venv's bin/ is already ahead
# of /usr/bin on PATH, so a CLI installed here is directly callable by the
# agent. Debian 13 marks the *system* python EXTERNALLY-MANAGED (PEP 668);
# targeting the venv sidesteps that rather than overriding it with
# --break-system-packages.
#
# Pinned, unlike the bare `ddgs` this replaces: an unpinned package in a
# rebuilt image is an unreviewed code change reaching an agent that has a
# shell. Bump it on purpose.
#
# 9.15.0, not the 9.16.0 that PyPI calls latest: 9.16.0 does not resolve
# against this image's Python 3.13 and uv silently settles on 9.15.0 when left
# unpinned. Pinning the resolved version is what makes that visible.
ARG HERMES_EXTRA_PYTHON_PACKAGES="ddgs==9.15.0"
RUN if [ -n "${HERMES_EXTRA_PYTHON_PACKAGES}" ]; then \
      uv pip install --python /opt/hermes/.venv --no-cache ${HERMES_EXTRA_PYTHON_PACKAGES}; \
    fi

# ── Attack surface ───────────────────────────────────────────
# Strip setuid/setgid bits. The agent runs as UID 10000 and s6-overlay drops
# privileges with its own supervision tooling rather than through setuid
# binaries, so nothing in the boot path needs them -- but `su`, `mount`,
# `chsh`, `gpasswd` and friends shipping with the bit set are a ready-made
# escalation path for anything that gets code execution as the agent.
#
# The listing is emitted before the change so the build log records exactly
# what was altered. Set to false if a future base image starts depending on one.
ARG HERMES_STRIP_SETUID=true
RUN if [ "${HERMES_STRIP_SETUID}" = "true" ]; then \
      echo "stripping setuid/setgid from:"; \
      find / -xdev -type f -perm /6000 -printf '  %M %p\n' 2>/dev/null || true; \
      find / -xdev -type f -perm /6000 -exec chmod -s {} + 2>/dev/null || true; \
    fi

# ── Healthcheck ──────────────────────────────────────────────
COPY --chmod=0755 scripts/healthcheck.sh /opt/rtk/bin/healthcheck.sh

# start-period is generous because a cold start pulls model config, migrates
# the session store and brings up s6 services before anything listens.
HEALTHCHECK --interval=30s --timeout=6s --start-period=180s --retries=3 \
    CMD ["/opt/rtk/bin/healthcheck.sh"]

# ── rtk PATH shims ───────────────────────────────────────────
# Last, and for two reasons: every RUN above uses the real `uv`, `find` and
# `curl` unfiltered, and generating the shims requires a PATH that does not yet
# contain them (install-shims.sh asserts this).
#
# `safe`       -- developer tooling only; nothing on the boot path. Default.
# `aggressive` -- adds ls/grep/find/curl/wc/diff/pip/uv. Bigger savings, and a
#                 real chance of breaking something that parses their output.
# `none`       -- ship rtk, shim nothing.
ARG RTK_SHIM_LEVEL=safe
COPY --chmod=0755 scripts/install-shims.sh /tmp/install-shims.sh
RUN /tmp/install-shims.sh "${RTK_SHIM_LEVEL}" \
    && rm -f /tmp/install-shims.sh

ENV PATH="/opt/rtk/shims:${PATH}"

# rtk keeps its config and its savings ledger under the XDG directories, which
# resolve from HOME. The upstream image already sets HOME=/opt/data, so both
# land inside the mounted volume without any override here: `rtk gain` survives
# a container recreate, and rtk never tries to write into the read-only
# application tree at /opt/hermes.
#
# XDG_CONFIG_HOME/XDG_DATA_HOME are deliberately NOT set -- they would apply to
# every process in the container, Hermes included, to relocate one tool.

# Telemetry is opt-in upstream; this makes the "off" explicit rather than
# inherited, so a future default flip cannot quietly start sending command
# metadata off this host.
ENV RTK_TELEMETRY_DISABLED=1

LABEL org.opencontainers.image.title="hermes-agent-rtk" \
      org.opencontainers.image.description="Nous Research Hermes agent with rtk output filtering and a hardened runtime posture" \
      org.opencontainers.image.base.name="${HERMES_BASE}" \
      org.opencontainers.image.base.digest="${HERMES_BASE_DIGEST}" \
      org.opencontainers.image.source="https://github.com/rtk-ai/rtk" \
      org.opencontainers.image.licenses="Apache-2.0" \
      fr.anvir.rtk.version="${RTK_VERSION}" \
      fr.anvir.rtk.shim-level="${RTK_SHIM_LEVEL}"
