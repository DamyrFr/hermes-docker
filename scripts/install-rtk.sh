#!/usr/bin/env bash
# Install a pinned, checksum-verified rtk into the image.
#
# Not `curl | sh` from upstream's install.sh on purpose: that script resolves
# "latest" at build time, which would make every rebuild of this image pull a
# different binary and silently change how the agent's command output is
# filtered. Version and hash are baked in instead, so a build either produces
# the rtk we tested against or fails.
set -euo pipefail

RTK_VERSION="${RTK_VERSION:?RTK_VERSION must be set}"
RTK_PREFIX="${RTK_PREFIX:-/opt/rtk}"
# Docker sets TARGETARCH on buildx; fall back to the host's own arch so a plain
# `docker build` on the target machine still works.
TARGETARCH="${TARGETARCH:-$(dpkg --print-architecture)}"

# The -oss edition. Since 1.0 the default rtk binary bundles the compression
# engine under BUSL-1.1; rtk-oss is Apache-2.0 only -- hook core and every
# command filter, no engine -- and is the edition that keeps this image's
# licenses label true and its public push unambiguous. Everything this stack
# does with rtk is command filtering (the PATH shims and the verbs in
# AGENTS.md), which the oss edition has in full.
#
# Upstream ships a musl build for x86_64 (fully static, no libc coupling to the
# Debian base) but only a glibc build for aarch64. Both run on debian:13.
case "$TARGETARCH" in
  amd64)
    asset="rtk-oss-x86_64-unknown-linux-musl.tar.gz"
    sha256="a44e8ffc43981100b4ddf1710399a1649a6c874591aa6d0c0727fe6cbd983c41"
    ;;
  arm64)
    asset="rtk-oss-aarch64-unknown-linux-gnu.tar.gz"
    sha256="ee24a43dac9162de55fea8460b5efcd56d401ec28b5117c921bffa8a57bc136e"
    ;;
  *)
    echo "install-rtk: unsupported architecture '$TARGETARCH'" >&2
    exit 1
    ;;
esac

# The checksums above are for one specific release. Refusing to guess at any
# other version is the whole point of pinning -- see `make rtk-digest`.
if [ "$RTK_VERSION" != "1.0.1" ]; then
  echo "install-rtk: no recorded checksum for rtk $RTK_VERSION." >&2
  echo "  Update the sha256 values in this script from" >&2
  echo "  https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/checksums.txt" >&2
  exit 1
fi

url="https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/${asset}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

echo "install-rtk: fetching $url"
curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
  --output "$workdir/$asset" "$url"

echo "${sha256}  ${workdir}/${asset}" | sha256sum --check --strict --quiet -

tar -xzf "$workdir/$asset" -C "$workdir"

# The tarball layout has moved between releases (bare binary vs. a versioned
# directory), so locate the binary rather than assuming a path.
binary="$(find "$workdir" -type f -name rtk -perm -u+x -print -quit)"
if [ -z "$binary" ]; then
  echo "install-rtk: no rtk binary found in $asset" >&2
  exit 1
fi

install -D -m 0755 -o root -g root "$binary" "${RTK_PREFIX}/bin/rtk"
ln -sf "${RTK_PREFIX}/bin/rtk" /usr/local/bin/rtk

# Fail the build now rather than shipping an image whose shims all fall back to
# the unfiltered binary at runtime.
installed="$(/usr/local/bin/rtk --version)"
echo "install-rtk: installed ${installed}"
case "$installed" in
  *"$RTK_VERSION"*) ;;
  *)
    echo "install-rtk: version mismatch, expected $RTK_VERSION, got '$installed'" >&2
    exit 1
    ;;
esac
