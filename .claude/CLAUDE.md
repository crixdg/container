# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

Infrastructure-as-code repository for deploying and managing containerized services across Docker Compose (local/dev) and Kubernetes (production). No application code — only service definitions, Helm chart values, and provisioning automation.

## Common Commands

### Docker Compose

```bash
# Start a service stack
docker-compose -f compose/<service>.yml up -d
docker-compose -f docker-composes/<service>/<file>.yaml up -d

# Stop and remove containers + volumes
docker-compose -f <file> down -v
```

### Kubernetes — Cluster Setup (Ansible)

```bash
# Full cluster provisioning (RHEL-based)
ansible-playbook -i ansible/kubernetes-setup/inventory/hosts.ini \
  ansible/kubernetes-setup/playbook/site.yml

# Individual steps
ansible-playbook -i ansible/kubernetes-setup/inventory/hosts.ini \
  ansible/kubernetes-setup/playbook/install_deps.rhel.yml
ansible-playbook -i ansible/kubernetes-setup/inventory/hosts.ini \
  ansible/kubernetes-setup/playbook/install.rhel.yml

# Reset cluster
ansible-playbook -i ansible/kubernetes-setup/inventory/hosts.ini \
  ansible/kubernetes-setup/playbook/clean.rhel.yml
```

### Kubernetes — Service Deployment (Helm)

```bash
# Render Helm values from environment variables (run before helm installs)
cd kubernetes && ./build-values.sh

# Install essential cluster components
./kubernetes/essential/cilium/install.sh
./kubernetes/essential/longhorn/install.sh
./kubernetes/essential/nginx-ingress-controller/install.sh

# Deploy a service
helm install <release> <repo>/<chart> -f helm-charts/<service>/helm-values.yaml -n <namespace> --create-namespace
helm upgrade <release> <repo>/<chart> -f helm-charts/<service>/helm-values.yaml -n <namespace>

# Common Helm repos needed
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add cilium https://helm.cilium.io
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

## Architecture

### Two Parallel Environments

**`compose/`** — Simple single-host Docker Compose files, minimal config, no env-var templating. Good for quick local spin-up.

**`docker-composes/`** — Environment-agnostic compose files using `${REGISTRY}`, `${VERSION}`, `${HOST_IP}` variables. Organized by service category. Intended for shared/multi-host deployments.

Both directories serve the same logical services; `docker-composes/` is the more complete and maintained version.

### Kubernetes Layout

- **`kubernetes/essential/`** — Must-install components: Cilium (CNI), Longhorn (storage), NGINX Ingress, Nexus (registry). Each has its own `install.sh` wrapper around `helm install`.
- **`kubernetes/temp/`** — Optional/experimental components (Harbor, HAProxy, Rook-Ceph).
- **`helm-charts/`** — Values overrides for all deployed Helm charts. These are not full chart definitions — they're `values.yaml` files passed with `-f` to existing community charts.
- **`kubernetes/config/.env`** — Cluster-level settings (`API_SERVER_IP`, `POD_NETWORK_CIDR`, credentials) sourced by `build-values.sh` via `envsubst`.

### Services and Their Ports

| Category      | Service                   | Docker Port                             |
| ------------- | ------------------------- | --------------------------------------- |
| Database      | PostgreSQL                | 5432                                    |
| Database      | Redis                     | 6379                                    |
| Database      | Cassandra                 | 9042                                    |
| Database      | MongoDB                   | 27017                                   |
| Streaming     | Kafka                     | 9092                                    |
| Streaming     | Schema Registry           | 8081                                    |
| Streaming     | Kafka Connect             | 8083                                    |
| Streaming     | AKHQ (Kafka UI)           | 8080                                    |
| IAM           | Keycloak                  | 19542 (docker-composes), 8070 (compose) |
| IAM           | Zitadel                   | 8080                                    |
| IAM           | Ory Hydra (public/admin)  | 4444 / 4445                             |
| IAM           | Ory Kratos (public/admin) | 4433 / 4434                             |
| Observability | Elasticsearch             | 9200                                    |
| Observability | Kibana                    | 5601                                    |
| Observability | Grafana                   | 3000                                    |
| Observability | Victoria Metrics          | 8428                                    |
| Observability | Jaeger UI                 | 16686                                   |
| Dev Tools     | SonarQube                 | 9000                                    |

### Observability Stack Design

Metrics pipeline: Node Exporter + cAdvisor + kube-state-metrics → Prometheus / Victoria Metrics → Grafana.
Tracing: OTEL Collector → Jaeger (collector → ingester → Elasticsearch → query UI).
Logs: ELK stack (Elasticsearch + Kibana).
In Kubernetes, `helm-charts/prometheus/helm-values.yaml` wires in exporters for Kafka, Cassandra, and Elasticsearch.

### IAM Options

Three independent IAM stacks are provided — use only one per deployment:

- **Keycloak** — mature, feature-rich, OIDC/SAML
- **Zitadel** — modern alternative, includes a pre-built login UI container
- **Ory** — split into Hydra (OAuth2 server) + Kratos (identity/user management), compose-network linked

### Ansible Provisioning

`ansible/kubernetes-setup/` provisions bare-metal RHEL hosts into a kubeadm cluster. The playbooks are ordered: deps → kernel config → firewall → kubeadm init/join. Two inventory files: `hosts.ini` (direct) and `hosts_jump.ini` (via bastion host).

## Key Configuration

- **`kubernetes/config/.env`** — Cluster API IP, pod CIDR, admin credentials. Edit before running `build-values.sh`.
- **`ansible/kubernetes-setup/inventory/hosts.ini`** — Node IPs and roles. Must be updated before running any playbook.
- **`docker-composes/`** compose files expect env vars like `${REGISTRY}`, `${HOST_IP}`, etc. to be exported in the shell before running `docker-compose up`.
