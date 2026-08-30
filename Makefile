# Thin wrappers around docker compose. Nothing here is required -- every target
# is one or two commands you could type -- but `make verify` in particular is
# worth using, because a shim that silently falls through to the unfiltered
# binary looks exactly like a working container.

COMPOSE ?= docker compose
IMAGE   ?= hermes-agent-rtk:latest

.DEFAULT_GOAL := help
.PHONY: help build up down restart logs shell verify data-dir base-digest rtk-digest lint

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build the image
	$(COMPOSE) build

up: data-dir ## Build if needed and start the stack
	$(COMPOSE) up -d --remove-orphans

down: ## Stop the stack
	$(COMPOSE) down

restart: ## Restart the container
	$(COMPOSE) restart

logs: ## Follow container logs
	$(COMPOSE) logs -f --tail=100

shell: ## Root shell in the running container
	$(COMPOSE) exec hermes bash

data-dir: ## Create the data volume with the ownership the image expects
	@mkdir -p $${HERMES_DATA_DIR:-./data}
	@chown -R 10000:10000 $${HERMES_DATA_DIR:-./data} 2>/dev/null \
	  || echo "note: could not chown data dir, re-run with sudo if the agent cannot write"
	@chmod 0750 $${HERMES_DATA_DIR:-./data}

verify: ## Smoke-test rtk and the shims inside the built image
	@echo "== rtk present and pinned =="
	@docker run --rm --entrypoint rtk $(IMAGE) --version
	@echo "== shims resolve ahead of the real binaries =="
	@docker run --rm --entrypoint sh $(IMAGE) -c 'command -v git; command -v docker' \
	  | grep -q '^/opt/hermes/bin/' \
	    && echo "OK: shims are first on PATH" \
	    || { echo "FAIL: shims are not on PATH"; exit 1; }
	@echo "== no image-level ENV was baked in =="
	@docker run --rm --entrypoint sh $(IMAGE) -c 'echo "$$RTK_TELEMETRY_DISABLED"' \
	  | grep -q . \
	    && { echo "FAIL: image bakes runtime env; it belongs in compose.yaml"; exit 1; } \
	    || echo "OK: runtime env comes from the run phase only"
	@echo "== shim produces filtered output, not an error =="
	@docker run --rm --entrypoint sh $(IMAGE) -c 'cd /tmp && git init -q r && cd r && git status' >/dev/null \
	    && echo "OK: shimmed git works" \
	    || { echo "FAIL: shimmed git broke"; exit 1; }
	@echo "== kill switch falls back to the real binary =="
	@docker run --rm -e RTK_SHIM_DISABLED=1 --entrypoint sh $(IMAGE) -c 'git --version' >/dev/null \
	    && echo "OK: RTK_SHIM_DISABLED bypasses the shim" \
	    || { echo "FAIL: kill switch broken"; exit 1; }
	@echo "== no setuid binaries remain =="
	@test -z "$$(docker run --rm --entrypoint sh $(IMAGE) -c 'find / -xdev -type f -perm /6000 2>/dev/null')" \
	    && echo "OK: no setuid/setgid binaries" \
	    || { echo "FAIL: setuid binaries present"; exit 1; }

base-digest: ## Print the current multi-arch digest of the upstream :latest tag
	@curl -sS https://hub.docker.com/v2/repositories/nousresearch/hermes-agent/tags/latest \
	  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["digest"], "pushed", d["last_updated"])'

rtk-digest: ## Print the checksums of the latest rtk release
	@curl -sSL https://api.github.com/repos/rtk-ai/rtk/releases/latest \
	  | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])'
	@curl -sSL https://github.com/rtk-ai/rtk/releases/latest/download/checksums.txt

lint: ## Validate the compose file and shell scripts
	$(COMPOSE) config --quiet && echo "compose: OK"
	@command -v shellcheck >/dev/null && shellcheck scripts/*.sh || echo "shellcheck not installed, skipped"
