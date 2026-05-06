INVENTORY     ?= inventory/hosts.ini
PLAYBOOK_DIR  := playbook
AP            := ansible-playbook -i $(INVENTORY)

.PHONY: help ping add-ssh-key

help:
	@echo "Usage: make <target> [INVENTORY=inventory/hosts.ini] [PUBKEY='ssh-rsa ...']"
	@echo ""
	@echo "Targets:"
	@echo "  ping         Verify connectivity to all hosts"
	@echo "  add-ssh-key  Copy SSH public key to root's authorized_keys on all hosts"
	@echo ""
	@echo "Examples:"
	@echo "  make add-ssh-key PUBKEY='ssh-rsa AAAA... user@host'"
	@echo "  make add-ssh-key INVENTORY=inventory/hosts.ini PUBKEY='ssh-rsa AAAA... user@host'"

ping:
	$(AP) -m ping all

add-ssh-key:
ifndef PUBKEY
	$(error PUBKEY is required. Usage: make add-ssh-key PUBKEY='ssh-rsa AAAA...')
endif
	$(AP) $(PLAYBOOK_DIR)/add-ssh-public-key.yml -e "pubkey=$(PUBKEY)"
