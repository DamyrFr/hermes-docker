# hermes-docker

The Nous Research Hermes agent image, with two things added: **rtk** output
filtering to cut token consumption, and a hardened runtime posture.

This repo builds the image. [`hermes-server`](../hermes-server) provisions the
host that runs it — firewall, tailscale, sshd, and the Ansible role that
deploys this stack.

## Quick start

```sh
cp .env.example .env && chmod 0600 .env
$EDITOR .env            # set HERMES_BIND_ADDR and the dashboard password
make up
make verify             # confirm rtk and the shims actually took effect
```

> **Gotcha, verified the hard way:** `HERMES_DASHBOARD_BASIC_AUTH_SECRET` must
> decode to **at least 16 bytes**. Below that, the basic-auth plugin silently
> declines to register and the dashboard refuses to bind with *"no auth
> providers are registered"* — an error that points at the wrong thing.
> `openssl rand -hex 32` is safely over the line.

The agent has no LLM provider until you run the wizard once:

```sh
docker run -it --rm -v "$PWD/data:/opt/data" nousresearch/hermes-agent:latest setup
make restart
```

## What rtk does here

[rtk](https://github.com/rtk-ai/rtk) is a CLI proxy that filters and summarises
command output before it reaches the model. Claude Code wires it in with a
`PreToolUse` hook; **Hermes has no equivalent interception point**, so this
image uses `PATH` shims instead — wrappers that sit ahead of `/usr/bin` and
re-exec through rtk.

They are installed into `/opt/hermes/bin`, which the base image already places
first on `PATH` and which holds only the `hermes` launcher. So the image sets
no `PATH` of its own: every environment variable this stack uses is declared in
the run phase (`compose.yaml` + `.env`), never baked into a layer. Changing one
is a restart, not a rebuild.

That is a real trade-off, and worth understanding before you raise the level:

| Level | Shims | Character |
|---|---|---|
| `none` | — | rtk installed, nothing intercepted. |
| `safe` *(default)* | `git docker rg tree npm npx tsc prettier cargo go mvn sbt pytest ruff mypy gh glab kubectl psql` | Developer tooling only. Nothing on the container's boot path. |
| `aggressive` | above **+** `ls grep find curl wget wc diff pip uv` | Largest savings. Also reshapes output for Hermes' own internals and every shell script in the image. |

Set it in `.env` (`RTK_SHIM_LEVEL`) and rebuild — it is a build argument.

Three properties make the shims recoverable when something does go wrong:

- **`RTK_SHIM_DISABLED=1`** in the environment turns every shim into a direct
  exec of the real binary. Restart, no rebuild.
- **Fallback on failure.** If rtk is missing, the shim execs the real binary
  rather than erroring.
- **No recursion.** rtk shells out to the binaries it wraps; the shims set
  `RTK_SHIM_BYPASS` before calling rtk so that inner call lands on the real
  binary.

`agents/AGENTS.md` is mounted read-only into `/opt/data` and tells the agent
about the rtk verbs a shim *cannot* provide — `rtk read`, `rtk err`, `rtk test`,
`rtk json`, `rtk log`, `rtk summary`. Those are where most of the remaining
savings are.

Check the payoff with `docker compose exec hermes rtk gain`. The ledger lives
in the data volume, so it survives a container recreate.

## What was hardened

**Build time** (`Dockerfile`)

- Base image tracked **by tag, resolved to a digest before the build**. The tag
  follows the release: `latest` normally, and the git tag itself on a release
  build, so `v0.22.5` of this image is built on
  `nousresearch/hermes-agent:v0.22.5`. CI resolves that tag to a digest once
  and hands the same digest to the verify build and the push build, so an
  upstream push landing mid-run cannot make it verify one image and ship
  another. `make base-digest` prints the digest for any tag.
- rtk pinned to a version **and a SHA-256**, downloaded from GitHub releases
  rather than piping upstream's `install.sh` into a shell. The **`rtk-oss`
  edition**: since 1.0 the default `rtk` binary bundles a BUSL-1.1 engine,
  while `rtk-oss` is Apache-2.0 only and carries every command filter — which
  is all this stack uses — keeping the image's `licenses` label true.
- Python packages pinned (`ddgs==9.15.0`, previously unpinned; plus the voice
  pair `faster-whisper==1.2.1` and `edge-tts==7.3.1`). Installed with a pinned
  `uv` that is bind-mounted for that one build step: upstream stopped shipping
  `uv` (and the venv has no `pip`) as of `v0.22.x`, and the mount keeps the
  installer out of the final image.
- `libopus0` (the Opus codec library) installed from the Debian suite for the
  agent's voice path — the base image does not ship it, and the Python wheels
  bundle their own copies of everything else they need.
- **setuid/setgid bits stripped** from every binary in the image. Nothing in
  the boot path needs them — s6-overlay drops privileges with its own tooling —
  and they are the readiest escalation path for anything that gets code
  execution as the agent.
- `HEALTHCHECK` that reports whether the gateway is actually serving.

**Runtime** (`compose.yaml`)

- `no-new-privileges:true` — no execve in this container can gain privilege.
- `cap_drop: ALL`, then back only `CHOWN FOWNER DAC_OVERRIDE SETUID SETGID
  KILL`. Drops the ~14 Docker grants by default, including `NET_RAW` (ARP and
  DNS spoofing on the bridge).
- `pids_limit: 512` and `nofile` ulimits, so a runaway tool takes the container
  down rather than the host.
- `HERMES_WRITE_SAFE_ROOT=/opt/data` — the agent cannot write outside the data
  volume.
- `HERMES_YOLO_MODE=0` stated explicitly.
- Per-container log caps, so an agent that logs every tool call cannot fill a
  small VPS's disk.
- Dashboard still published to the tailnet address only, never `0.0.0.0`.
- The Docker socket is **not** mounted, and the compose file says why.

`read_only: true` is left off deliberately — s6 writes to `/run` and Playwright
wants an executable `/tmp`. The commented block in `compose.yaml` has the tmpfs
mounts it would need.

**The agent's own config** is the one layer this repo cannot set for you.
Hermes writes `/opt/data/config.yaml` through an interactive wizard and owns
that file. `config/security.recommended.yaml` documents the keys worth changing
— approval mode, the deny globs, `allow_lazy_installs`, `env_passthrough` —
with the reasoning for each. Merge it by hand, once.

## Layout

```
Dockerfile                        image: rtk + pinning + setuid strip
compose.yaml                      runtime: capabilities, limits, bind address
agents/AGENTS.md                  read-only context file: how to use rtk
config/security.recommended.yaml  reference for the agent's own config.yaml
scripts/install-rtk.sh            pinned, checksum-verified rtk install
scripts/install-shims.sh          shim generation, the levels, the bypass
scripts/healthcheck.sh            dashboard liveness probe
```

## CI

`.github/workflows/build-push.yml` builds, **verifies**, then pushes to Docker
Hub. Pull requests build and verify but never push.

The verify gate is the point of the workflow. Almost everything this image adds
fails silently — a shim that falls through to the unfiltered binary looks
exactly like a working one — so CI builds amd64, loads it, runs `make verify`,
and boots a container under the same capability set `compose.yaml` uses,
failing on any permission error during s6 init. Only then does it push.

Configure once, in **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
|---|---|---|
| Variable *(or Secret)* | `DOCKERHUB_REPOSITORY` | e.g. `damyr/hermes-agent` |
| Secret | `DOCKERHUB_USERNAME` | your Docker Hub user |
| Secret | `DOCKERHUB_TOKEN` | an access token, **not** your password |

> **The Variables and Secrets tabs are separate namespaces.** A value added
> under Secrets is invisible to `vars.*` and vice versa — which produces a
> confusing "not set" failure for a value you can see in the UI. The workflow
> therefore reads `DOCKERHUB_REPOSITORY` from **either** tab.

Prefer the **Variables** tab for it: it is not a credential, and as a secret it
gets masked, so every log line naming the image — including the pushed tags in
the run summary — renders as `***`. The build still works either way; the
workflow prints a warning when it had to fall back to the secret.

Create the token at Docker Hub → Account Settings → Personal access tokens,
scoped **Read & Write** — nothing here needs Delete.

### Tags

| You push | Built on | Published as |
| --- | --- | --- |
| a commit to `main` | `nousresearch/hermes-agent:latest` | `latest`, `sha-<short>` |
| the git tag `v0.22.5` | `nousresearch/hermes-agent:v0.22.5` | `v0.22.5`, `sha-<short>` |

A release is therefore just a git tag named after the upstream tag you want to
build on:

```sh
git tag v0.22.5 && git push origin v0.22.5
```

Check the name against [upstream's tags](https://hub.docker.com/r/nousresearch/hermes-agent/tags)
first — `make base-digest BASE_TAG=v0.22.5` does it from the shell. Upstream
switched schemes in October 2026: releases up to `v2026.9.24` were date-based
(calver), from `v0.22.2` on they are `v0.MINOR.PATCH`. A date-style tag such
as `v2026.10.15` no longer exists upstream and cannot be released here. Ignore
the `rc.*`, `stable` and `*-desktop` tags upstream also publishes; build on
the plain `vX.Y.Z` ones.

The tag is used **verbatim** on both ends — the point is that your `v0.22.5`
and upstream's are the same release, so nothing normalises it. That rules out
`type=semver` in the workflow: it would strip the `v`, and it would drop the
four-part calver tags (`v2026.8.16.2`) that older releases used.

Tag something upstream does not publish and the run fails in its first minute,
naming the tag, rather than deep inside a build. Two caveats worth knowing:
a `v*` tag on a docs-only commit is skipped by `paths-ignore`, and a release
does **not** move `latest` — `latest` follows `main`, as it does upstream.
Either case is covered by running the workflow manually against the tag ref,
which also takes a *base tag* input for rebuilding an old release on a newer
base.

Builds attach **provenance and an SBOM**, which is what makes the pinning
checkable by whoever pulls the image rather than only by whoever built it.

Builds are `linux/amd64` by default — what the VPS runs and what the image is
tested on. arm64 works (`install-rtk.sh` handles it, the base is multi-arch)
but is QEMU-emulated on GitHub runners, so it is opt-in: run the workflow
manually and set *Target platforms* to `linux/amd64,linux/arm64`, or change the
`PLATFORMS` default. The same dispatch form can build at `aggressive` shim
level.

Upstream Hermes is MIT-licensed, so publishing a derived image is fine; keep
the base image's licence notice intact.

## Maintenance

```sh
make base-digest                    # digest of upstream :latest
make base-digest BASE_TAG=v0.22.5    # ... or of a specific tag
make rtk-digest     # latest rtk tag + checksums -> paste into install-rtk.sh
make lint           # compose config + shellcheck
make verify         # smoke-test the built image
```

Both pins are meant to be bumped deliberately. `install-rtk.sh` refuses to
build if `RTK_VERSION` does not match the version its checksums were recorded
for, rather than downloading something it cannot verify.
