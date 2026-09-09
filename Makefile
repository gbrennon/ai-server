.PHONY: deploy build models service check syntax

# Deploy everything to localhost
build:
	ansible-galaxy collection install -r requirements.yml -f
	ansible-playbook site.yml --connection=local

deploy:
	ansible-galaxy collection install -r requirements.yml -f
	ansible-playbook site.yml

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
