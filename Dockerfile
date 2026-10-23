# syntax=docker/dockerfile:1.7
#
# ─────────────────────────────────────────────────────────────
# Hermes agent: instrumented and hardened.
#
# Three things sit on top of the upstream image:
#   1. rtk (github.com/rtk-ai/rtk) -- pinned, checksum-verified -- plus PATH
#      shims that route selected commands through it, because Hermes has no
#      PreToolUse hook to rewrite commands the way Claude Code does.
#   2. The agent's extra packages, version-pinned: libopus0 from the Debian
#      suite, plus the Python packages in the agent's virtualenv -- the voice
#      pair faster-whisper and edge-tts among them.
#   3. Build-time attack-surface reduction: setuid/setgid bits stripped.
#
# What is deliberately NOT here: capabilities, no-new-privileges, pids limits,
# read-only rootfs. An image cannot drop its own privileges -- those live in
# compose.yaml, and an image built from this file but run without that compose
# file is not the hardened thing.
# ─────────────────────────────────────────────────────────────

# Which upstream image to build on, and at which tag.
#
# `latest` by default: a push to main builds on upstream's latest and publishes
# ours as `latest`. A release build passes the git tag instead, so `v0.22.3`
# of this image is built from `nousresearch/hermes-agent:v0.22.3` and the
# two tags name the same upstream release. Nothing here has to be edited for
# that -- CI derives the tag from the ref it was triggered on.
#
# HERMES_BASE_PIN is empty by default and, when set, holds `@sha256:...` --
# the `@` included -- for a caller that has already resolved the tag to a
# digest. CI resolves it once and passes the same value to the verify build and
# the push build, so a tag that moves upstream between the two cannot leave us
# verifying one image and shipping another. `make base-digest BASE_TAG=<tag>`
# prints the digest to build one out of.
#
# Registry spelled out rather than left as a short name: Docker would infer
# docker.io, but Podman refuses to guess, and an explicit registry is one fewer
# thing a search-registry setting can redirect.
ARG HERMES_BASE=docker.io/nousresearch/hermes-agent
ARG HERMES_BASE_TAG=latest
ARG HERMES_BASE_PIN=

FROM ${HERMES_BASE}:${HERMES_BASE_TAG}${HERMES_BASE_PIN}

# An ARG declared above the first FROM is visible to FROM lines and nowhere
# else. Re-declare the three the LABEL block at the bottom interpolates --
# without this they expand to the empty string there, silently.
ARG HERMES_BASE
ARG HERMES_BASE_TAG
ARG HERMES_BASE_PIN

# Upstream's entrypoint starts s6-overlay as root PID 1 and drops to UID 10000
# itself. Pinning a USER at the end of this file would break that, so every
# layer below runs as root and the image stays root-entrypointed on purpose.
USER root

# pipefail so a failure on the left of a pipe fails the build instead of being
# masked by a successful tail.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ── rtk ──────────────────────────────────────────────────────
ARG RTK_VERSION=1.0.1
# Set by buildx; install-rtk.sh falls back to dpkg when building without it.
ARG TARGETARCH

COPY --chmod=0755 scripts/install-rtk.sh /tmp/install-rtk.sh
RUN RTK_VERSION="${RTK_VERSION}" TARGETARCH="${TARGETARCH}" \
      /tmp/install-rtk.sh \
    && rm -f /tmp/install-rtk.sh

# ── Extra system packages ────────────────────────────────────
# libopus0, the Opus codec library the agent's voice path loads to encode and
# decode audio. Absent from the base image as of v0.22.3, and nothing below
# pulls it in either -- every wheel in the Python stack bundles its own copies
# of the libraries it needs -- so it is installed explicitly rather than left
# to arrive as someone's side effect. Versioning comes from the suite: the
# base is Debian 13 (trixie), which ships exactly one libopus.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libopus0 \
    && rm -rf /var/lib/apt/lists/*

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
# 9.15.0 was picked when the base ran Python 3.13, where 9.16.0 did not
# resolve. Since v0.22.x the base is on Python 3.14 and 9.16.0 resolves too;
# moving to it is a deliberate bump, not something to let drift in.
#
# The voice pair exists for the agent's speech loop: faster-whisper turns
# audio into text through CTranslate2 (no system ffmpeg needed -- PyAV bundles
# the decode libraries), and edge-tts turns text back into speech through
# Microsoft Edge's online service. Both were resolved against the venv's
# Python 3.14 before pinning: every wheel in their trees, `av` and
# `onnxruntime` included, has a build that satisfies it.
#
# uv is bind-mounted for this one step rather than taken from the base:
# upstream shipped /usr/local/bin/uv up to v2026.9.24 and dropped it in v0.22.x
# (the venv has no pip either), so relying on it fails with exit 127. A mount
# also keeps the installer out of the final image -- nothing at runtime needs
# it. Pinned to the uv the base used to ship.
ARG HERMES_EXTRA_PYTHON_PACKAGES="ddgs==9.15.0 edge-tts==7.3.1 faster-whisper==1.2.1"
RUN --mount=from=ghcr.io/astral-sh/uv:0.11.6,source=/uv,target=/usr/local/bin/uv \
    if [ -n "${HERMES_EXTRA_PYTHON_PACKAGES}" ]; then \
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
#
# Mirrored as a compose-level healthcheck in compose.yaml, which overrides
# this one when the stack runs under Compose and survives the OCI image
# format's lack of a healthcheck field -- keep the two in sync.
HEALTHCHECK --interval=30s --timeout=6s --start-period=180s --retries=3 \
    CMD ["/opt/rtk/bin/healthcheck.sh"]

# ── rtk PATH shims ───────────────────────────────────────────
# Last, so every RUN above uses the real `uv`, `find` and `curl` unfiltered.
#
# The shims land in /opt/hermes/bin, which the base image already puts first on
# PATH. That is deliberate: no `ENV PATH` here, and nothing to re-declare at run
# time. Setting PATH ourselves would either bake an image-level env var (this
# stack keeps environment in the run phase) or force compose to restate the
# base image's whole PATH, which silently rots when upstream changes it.
#
# `safe`       -- developer tooling only; nothing on the boot path. Default.
# `aggressive` -- adds ls/grep/find/curl/wc/diff/pip/uv. Bigger savings, and a
#                 real chance of breaking something that parses their output.
# `none`       -- ship rtk, shim nothing.
ARG RTK_SHIM_LEVEL=safe
COPY --chmod=0755 scripts/install-shims.sh /tmp/install-shims.sh
RUN /tmp/install-shims.sh "${RTK_SHIM_LEVEL}" \
    && rm -f /tmp/install-shims.sh

# No ENV block on purpose. Every runtime variable -- RTK_TELEMETRY_DISABLED,
# RTK_SHIM_DISABLED, the HERMES_* settings -- is set in the run phase, from
# compose.yaml and .env, so that changing one is a restart rather than a
# rebuild and there is a single place to read the container's configuration.

LABEL org.opencontainers.image.title="hermes-agent-damyr" \
      org.opencontainers.image.description="Nous Research Hermes agent with rtk output filtering and a hardened runtime posture" \
      org.opencontainers.image.base.name="${HERMES_BASE}:${HERMES_BASE_TAG}${HERMES_BASE_PIN}" \
      org.opencontainers.image.source="https://github.com/rtk-ai/rtk" \
      org.opencontainers.image.licenses="Apache-2.0" \
      fr.anvir.rtk.version="${RTK_VERSION}" \
      fr.anvir.rtk.shim-level="${RTK_SHIM_LEVEL}"
