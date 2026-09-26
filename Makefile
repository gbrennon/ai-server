.DEFAULT_GOAL := help

.PHONY: help help-all deploy build models service check syntax lint deploy-gmktec deploy-gmktec-setup register-gmktec-model unregister-gmktec-model deploy-interactive deploy-gateway verify-pi-ratatui verify-omp-parallel qemu-verify qemu-verify-gmktec build-only models-only service-only gateway-only verify-gateway verify-gateway-container trust-caddy-ca

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*##"; print "Available commands:"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# Deploy everything to localhost
build: ## Build locally
	ansible-galaxy collection install -r requirements.yml -f
	ansible-playbook site.yml --connection=local

deploy: ## Deploy to the default host
	ansible-galaxy collection install -r requirements.yml -f
	ansible-playbook site.yml

# Deploy to the GMKtec EVO X2 mini PC (GPU/Vulkan)
# Usage: make deploy-gmktec HOST=<ip> [USER=<user>]
deploy-gmktec: ## Deploy to a GMKtec EVO X2
	./scripts/deploy-gmktec.sh $(HOST) $(USER)

# One-time bootstrap of a fresh GMKtec (SSH key + passwordless sudo), then deploy
# Usage: make deploy-gmktec-setup HOST=<ip> [USER=<user>]
deploy-gmktec-setup: ## Bootstrap and deploy a GMKtec EVO X2
	./scripts/deploy-gmktec.sh $(HOST) $(USER) --setup

register-gmktec-model: ## Detect and register the deployed model in Pi and OMP
	./scripts/sync-client-model.sh register profiles/gmktec-evo-x2.yml

unregister-gmktec-model: ## Remove the GMKtec profile provider from Pi and OMP
	./scripts/sync-client-model.sh unregister profiles/gmktec-evo-x2.yml

# Interactive deployment wizard (prompts for IP, username, profile, and password)
deploy-interactive: ## Interactive deployment wizard (IP, user, password, auto-deploy)
	./scripts/deploy-interactive.sh

# End-to-end verification with Pi agent (Rust + Ratatui app generation)
verify-pi-ratatui: ## Verify deployed local model with Pi agent creating Ratatui Rust app
	./scripts/verify-pi-ratatui.sh
# End-to-end verification with OMP agent (2 parallel slots + concurrency benchmark)
verify-omp-parallel: ## Verify local model parallel execution (2 slots) with OMP agent
	./scripts/verify-omp-parallel.sh


# Verify the automation end-to-end in a local QEMU VM (CPU backend)
qemu-verify: ## Verify the automation in a local QEMU VM
	./scripts/qemu-verify.sh

# Verify the GMKtec EVO X2 profile in a local QEMU VM (no GPU: cpu backend + small model)
qemu-verify-gmktec: ## Verify the GMKtec profile in QEMU
	./scripts/qemu-verify-gmktec.sh

# Re-run only specific stages
build-only: ## Re-run only the build stage
	ansible-playbook site.yml --tags build --connection=local

models-only: ## Re-run only the models stage
	ansible-playbook site.yml --tags models --connection=local

service-only: ## Re-run only the service stage
	ansible-playbook site.yml --tags service --connection=local

# Sanity checks
syntax: ## Run the Ansible syntax check
	ansible-playbook site.yml --syntax-check

lint: ## Run Ansible lint
	ansible-lint site.yml roles/ 2>/dev/null || echo "ansible-lint not installed; skipping"


# Gateway (optional) stage helpers
# Usage: make deploy-gateway HOST=<ip> [USER=<user>] [LAN_IP=<ip>]
deploy-gateway: ## Deploy only the gateway (Caddy + dnsmasq) to a remote host
	./scripts/deploy-gateway.sh $(HOST) $(USER) $(LAN_IP)

gateway-only: ## Re-run only the gateway stage locally (set GATEWAY_LAN_IP)
	ansible-playbook site.yml --tags gateway --connection=local \
		-e gateway_enabled=true -e gateway_lan_ip=$(GATEWAY_LAN_IP)

verify-gateway: ## Run the gateway health check (requires stack up)
	./scripts/verify-gateway.sh

verify-gateway-container: ## Verify the gateway role in an isolated systemd container
	./scripts/verify-gateway-container.sh

trust-caddy-ca: ## Trust Caddy's internal root CA system-wide (sudo)
	sudo ./scripts/trust-caddy-ca.sh
