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

# Upstream ships a musl build for x86_64 (fully static, no libc coupling to the
# Debian base) but only a glibc build for aarch64. Both run on debian:13.
case "$TARGETARCH" in
  amd64)
    asset="rtk-x86_64-unknown-linux-musl.tar.gz"
    sha256="79aa5b89c69566bbfeceb66c8a27cfbe52237fc7ee3e683115f43745a3262d21"
    ;;
  arm64)
    asset="rtk-aarch64-unknown-linux-gnu.tar.gz"
    sha256="e8c2e1787f46017ea7c5a711b2bc6a7f7cf61c7ad69385b4c1e4daff1135dcd1"
    ;;
  *)
    echo "install-rtk: unsupported architecture '$TARGETARCH'" >&2
    exit 1
    ;;
esac

# The checksums above are for one specific release. Refusing to guess at any
# other version is the whole point of pinning -- see `make rtk-digest`.
if [ "$RTK_VERSION" != "0.46.0" ]; then
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
