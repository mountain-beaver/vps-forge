# vps-forge developer tasks. Needs bash, shellcheck, python3 + PyYAML and zip; the container
# suites also need podman or docker.

SKILL   := skills/vps-forge
VERSION := $(shell python3 -c 'import json;print(json.load(open(".claude-plugin/plugin.json"))["version"])')
DIST    := dist
DISTRO  ?= all

.PHONY: help test lint templates audit audit-systemd deadman-systemd ci package directory eval clean

help: ## list targets
	@awk -F':.*## ' '/^[a-z-]+:.*## /{printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: ## lint + JSON/YAML + versions + audit smoke + deadman (rootless via unshare)
	bash tests/run.sh

lint: ## only the static checks (no containers, no network, no root)
	VPS_FORGE_LINT_ONLY=1 bash tests/run.sh

templates: ## validate config templates with real tools in containers (DISTRO=debian:13 for one)
	bash tests/in-container.sh $(DISTRO) templates

audit: ## audit.sh behaviour scenarios in containers (DISTRO=ubuntu:24.04 for one)
	bash tests/in-container.sh $(DISTRO) audit

audit-systemd: ## audit.sh checks that need systemd (podman, localhost/u24sd)
	bash tests/audit-systemd.sh

deadman-systemd: ## deadman with real systemd in podman (localhost/u24sd, ~90 s, needs network)
	bash tests/deadman-systemd.sh

ci: ## everything CI runs, locally, in containers
	bash tests/in-container.sh $(DISTRO)

package: ## build dist/vps-forge-skill.zip for claude.ai upload (same as the release workflow)
	@mkdir -p $(DIST) && rm -f $(DIST)/vps-forge-skill.zip
	cd skills && zip -qr -X $(CURDIR)/$(DIST)/vps-forge-skill.zip vps-forge -x 'vps-forge/evals/*'
	@echo "$(DIST)/vps-forge-skill.zip ($(VERSION))"

directory: ## build dist/directory: the plugin folder Anthropic's directory reads (same as the directory workflow)
	rm -rf $(DIST)/directory && .github/directory/build.sh $(DIST)/directory

# Pin the judge and use a 0.85 threshold so llm grader noise is not a gate; see CONTRIBUTING.md.
eval: ## behaviour evals with `claude plugin eval` (spends tokens)
	cd $(SKILL) && claude plugin eval . --allow-tools Write,Edit,Bash --scaffold --threshold 0.85 --judge-model claude-haiku-4-5

clean: ## remove build output
	rm -rf $(DIST)
