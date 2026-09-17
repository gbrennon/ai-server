.DEFAULT_GOAL := help

.PHONY: help deploy build models service check syntax lint deploy-gmktec deploy-gmktec-setup qemu-verify qemu-verify-gmktec build-only models-only service-only

help: ## Show available commands
	@echo "Available commands:"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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
