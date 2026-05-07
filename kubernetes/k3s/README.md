# k3s Cluster Setup

Lightweight Kubernetes cluster provisioning using k3s. Supports single-node and multi-node HA setups via manual scripts or Ansible.

## Directory Layout

```
kubernetes/k3s/
├── registries.yaml        # Private registry config (place on nodes before install)
├── scripts/
│   ├── .env.server.example      # Server config template — copy to .env on server nodes
│   ├── .env.agent.example       # Agent config template — copy to .env on agent nodes
│   ├── install-server.sh        # Bootstrap a server node (Debian + RHEL)
│   ├── install-agent.sh         # Join a worker node (Debian + RHEL)
│   ├── uninstall.sh             # Remove k3s from a node
│   ├── install-essentials.sh    # Install cert-manager + ingress-nginx + Longhorn
│   ├── set-default-storageclass.sh  # Switch default StorageClass to Longhorn
│   └── prerequisites.sh         # Check section 1.1 prerequisites (Debian + RHEL)
├── ansible/
│   ├── inventory/
│   │   └── hosts.ini            # Node IPs and roles
│   ├── group_vars/
│   │   └── all.example.yml      # Cluster variables template — copy to all.yml
│   └── playbook/
│       ├── site.yml       # Full cluster provisioning (runs all steps)
│       ├── preflight.yml  # System checks and prerequisites
│       ├── firewall.yml   # Open required ports
│       ├── install-servers.yml
│       ├── install-agents.yml
│       └── clean.yml      # Tear down the cluster
├── helm/
│   ├── cert-manager/
│   ├── ingress-nginx/
│   └── longhorn/
└── docs/                  # Architecture and migration guides
```

## Prerequisites

- Target nodes running a systemd-based Linux distribution (RHEL, Ubuntu, Debian, etc.)
- Root or passwordless sudo access on all nodes
- Ansible installed on the machine you run playbooks from (for the Ansible path)

## Quick Start

### 1. Configure

```bash
# on server nodes
cp kubernetes/k3s/scripts/.env.server.example kubernetes/k3s/scripts/.env

# on agent nodes
cp kubernetes/k3s/scripts/.env.agent.example kubernetes/k3s/scripts/.env

# for Ansible
cp kubernetes/k3s/ansible/group_vars/all.example.yml kubernetes/k3s/ansible/group_vars/all.yml
```

Edit `.env` and set at minimum:

| Variable          | Description                                     |
| ----------------- | ----------------------------------------------- |
| `FIRST_SERVER_IP` | IP of the first (bootstrap) server node         |
| `K3S_VERSION`     | Pin a release, e.g. `v1.35.4+k3s1`              |
| `CLUSTER_CIDR`    | Pod network CIDR (default `10.42.0.0/16`)       |
| `SERVICE_CIDR`    | Service network CIDR (default `10.43.0.0/16`)   |
| `EXTRA_SANS`      | Extra IPs/hostnames for the API server TLS cert |

### 2a. Provision with Ansible (recommended for multi-node)

Edit `ansible/inventory/hosts.ini` to match your node IPs:

```ini
[k3s_servers]
server-01 ansible_host=192.168.1.100 ansible_user=root

[k3s_agents]
agent-01 ansible_host=192.168.1.110 ansible_user=root
```

Run the full provisioning sequence:

```bash
ansible-playbook -i kubernetes/k3s/ansible/inventory/hosts.ini \
                 kubernetes/k3s/ansible/playbook/site.yml
```

Individual steps:

```bash
ansible-playbook -i kubernetes/k3s/ansible/inventory/hosts.ini \
                 kubernetes/k3s/ansible/playbook/preflight.yml

ansible-playbook -i kubernetes/k3s/ansible/inventory/hosts.ini \
                 kubernetes/k3s/ansible/playbook/firewall.yml

ansible-playbook -i kubernetes/k3s/ansible/inventory/hosts.ini \
                 kubernetes/k3s/ansible/playbook/install-servers.yml

ansible-playbook -i kubernetes/k3s/ansible/inventory/hosts.ini \
                 kubernetes/k3s/ansible/playbook/install-agents.yml
```

### 2b. Provision manually (single-node or quick testing)

On the server node (set `NODE_IP` in `.env` first):

```bash
sudo bash kubernetes/k3s/scripts/install-server.sh
```

The script prints the node token and kubeconfig instructions when it finishes.

On each worker node:

```bash
K3S_SERVER_URL=https://<server-ip>:6443 \
K3S_TOKEN=<token-from-server>          \
sudo bash kubernetes/k3s/scripts/install-agent.sh
```

### 3. Configure kubectl

From the server node:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
```

From a remote workstation:

```bash
scp root@<server-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s.yaml
sed -i 's/127.0.0.1/<server-ip>/g' ~/.kube/k3s.yaml
export KUBECONFIG=~/.kube/k3s.yaml
kubectl get nodes
```

### 4. Install essential cluster components

```bash
bash kubernetes/k3s/scripts/install-essentials.sh
```

This installs in dependency order:

1. **cert-manager** — TLS certificate management
2. **ingress-nginx** — Ingress controller (Traefik is disabled by default)
3. **Longhorn** — Distributed block storage

## Private Registry

If you pull images from a private registry, place `registries.yaml` on each node **before** installing k3s:

```bash
cp kubernetes/k3s/registries.yaml /etc/rancher/k3s/registries.yaml
# edit the file, then run install-server.sh / install-agent.sh
```

After a registry change on an already-running cluster, restart k3s:

```bash
systemctl restart k3s          # server node
systemctl restart k3s-agent    # agent nodes
```

## Uninstall

```bash
sudo bash kubernetes/k3s/scripts/uninstall.sh
```

Or via Ansible to wipe all nodes at once:

```bash
ansible-playbook -i kubernetes/k3s/ansible/inventory/hosts.ini \
                 kubernetes/k3s/ansible/playbook/clean.yml
```

## Reference Docs

| File                                                 | Topic                                          |
| ---------------------------------------------------- | ---------------------------------------------- |
| `docs/1_k3s_components.md`                           | Core k3s components overview                   |
| `docs/2_k3s_container_runtime.md`                    | Container runtime configuration                |
| `docs/3_k3s_pod_networking.md`                       | Pod networking (Flannel default)               |
| `docs/3.1_k3s_flannel_to_cillium.md`                 | Migrating CNI from Flannel to Cilium           |
| `docs/3.2_k3s_flannel_to_cilium_maintenance.md`      | Cilium migration — maintenance window approach |
| `docs/3.3_k3s_flannel_to_cilium_blue_green.md`       | Cilium migration — blue/green approach         |
| `docs/4_k3s_cluster_dns.md`                          | Cluster DNS (CoreDNS)                          |
| `docs/5_k3s_state_store.md`                          | etcd vs embedded SQLite                        |
| `docs/6_k3s_storage.md`                              | Storage classes and PV provisioning            |
| `docs/6.1_k3s_local_path_to_longhorn.md`             | Migrating from local-path to Longhorn          |
| `docs/6.2_k3s_local_path_to_longhorn_no_downtime.md` | Zero-downtime storage migration                |
| `docs/7_k3s_ingress.md`                              | Ingress setup and configuration                |
| `docs/8_k3s_load_balancer.md`                        | Load balancer options (MetalLB vs Klipper)     |
| `docs/9_k3s_production_readiness.md`                 | Post-install production readiness checklist    |
| `docs/10_k3s_cluster_testing.md`                     | Resilience, chaos, and upgrade testing         |
| `docs/11_k3s_load_and_chaos.md`                      | Load testing and chaos under live traffic      |
