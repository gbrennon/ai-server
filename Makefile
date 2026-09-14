.PHONY: deploy build models service check syntax deploy-gmktec deploy-gmktec-setup qemu-verify qemu-verify-gmktec

# Deploy everything to localhost
build:
	ansible-galaxy collection install -r requirements.yml -f
	ansible-playbook site.yml --connection=local

deploy:
	ansible-galaxy collection install -r requirements.yml -f
	ansible-playbook site.yml

# Deploy to the GMKtec EVO X2 mini PC (GPU/Vulkan)
# Usage: make deploy-gmktec HOST=<ip> [USER=<user>]
deploy-gmktec:
	./scripts/deploy-gmktec.sh $(HOST) $(USER)

# One-time bootstrap of a fresh GMKtec (SSH key + passwordless sudo), then deploy
# Usage: make deploy-gmktec-setup HOST=<ip> [USER=<user>]
deploy-gmktec-setup:
	./scripts/deploy-gmktec.sh $(HOST) $(USER) --setup

# Verify the automation end-to-end in a local QEMU VM (CPU backend)
qemu-verify:
	./scripts/qemu-verify.sh

# Verify the GMKtec EVO X2 profile in a local QEMU VM (no GPU: cpu backend + small model)
qemu-verify-gmktec:
	./scripts/qemu-verify-gmktec.sh

# Re-run only specific stages
build-only:
	ansible-playbook site.yml --tags build --connection=local

models-only:
	ansible-playbook site.yml --tags models --connection=local

service-only:
	ansible-playbook site.yml --tags service --connection=local

# Sanity checks
syntax:
	ansible-playbook site.yml --syntax-check

lint:
	ansible-lint site.yml roles/ 2>/dev/null || echo "ansible-lint not installed; skipping"
