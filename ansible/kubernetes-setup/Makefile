INVENTORY     ?= inventory/hosts.ini
PLAYBOOK_DIR  := playbook
AP            := ansible-playbook -i $(INVENTORY)

.PHONY: help ping deps kernel firewall install site clean

help:
	@echo "Usage: make <target> [INVENTORY=inventory/hosts_jump.ini]"
	@echo ""
	@echo "Targets:"
	@echo "  ping      Verify connectivity to all hosts"
	@echo "  deps      Install packages and container runtime"
	@echo "  kernel    Configure kernel parameters"
	@echo "  firewall  Configure firewall rules"
	@echo "  install   Run kubeadm init/join"
	@echo "  site      Full provisioning (deps → kernel → firewall → install)"
	@echo "  clean     Reset and tear down the cluster"
	@echo ""
	@echo "Override inventory:  make site INVENTORY=inventory/hosts_jump.ini"

ping:
	$(AP) $(PLAYBOOK_DIR)/ping.rhel.yml

deps:
	$(AP) $(PLAYBOOK_DIR)/install_deps.rhel.yml

kernel:
	$(AP) $(PLAYBOOK_DIR)/config_kernel.rhel.yml

firewall:
	$(AP) $(PLAYBOOK_DIR)/config_firewall.rhel.yml

install:
	$(AP) $(PLAYBOOK_DIR)/install.rhel.yml

site:
	$(AP) $(PLAYBOOK_DIR)/install_deps.rhel.yml
	$(AP) $(PLAYBOOK_DIR)/config_kernel.rhel.yml
	$(AP) $(PLAYBOOK_DIR)/config_firewall.rhel.yml
	$(AP) $(PLAYBOOK_DIR)/install.rhel.yml

clean:
	$(AP) $(PLAYBOOK_DIR)/clean.rhel.yml
