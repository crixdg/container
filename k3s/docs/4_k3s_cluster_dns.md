# k3s Cluster DNS

CoreDNS is the DNS server that runs inside every k3s cluster. It gives every Service a stable hostname so that pods can discover each other by name instead of by IP address.

**Where CoreDNS sits in the k3s system:**

```
Pod A wants to reach "my-service.app.svc.cluster.local"
    │
    ▼
/etc/resolv.conf (inside Pod A)
    nameserver 10.43.0.10   ← ClusterIP of the CoreDNS Service
    │
    ▼
CoreDNS Pod (kube-system)
    │
    ├── Name is a cluster Service?  →  return the ClusterIP
    ├── Name is a Pod IP record?    →  return the Pod IP
    └── Name is external?           →  forward to upstream DNS (host /etc/resolv.conf)
```

> CoreDNS itself has a Service with a fixed ClusterIP (`10.43.0.10` by default). k3s passes this IP to kubelet, which injects it as `nameserver` into every pod's `/etc/resolv.conf` at startup.

---

## How DNS names are structured

Every Service and Pod in the cluster gets a DNS name following this pattern:

```
<name>.<namespace>.svc.cluster.local
```

| Segment         | Meaning                                           |
| --------------- | ------------------------------------------------- |
| `<name>`        | Name of the Service object                        |
| `<namespace>`   | Namespace the Service lives in                    |
| `svc`           | Indicates this is a Service record                |
| `cluster.local` | The cluster domain (configurable, rarely changed) |

**Example — a PostgreSQL Service in the `database` namespace:**

```
postgres.database.svc.cluster.local   →   10.43.45.12   (ClusterIP)
```

> Pods within the same namespace can omit the namespace and suffix — `postgres` alone resolves correctly.
> Pods in a different namespace must use at least `postgres.database`.
> The full FQDN `postgres.database.svc.cluster.local` works from anywhere.

**Search domains** — k3s injects search suffixes into every pod's `/etc/resolv.conf` so short names resolve automatically:

```
# /etc/resolv.conf inside a pod in namespace "app"
nameserver 10.43.0.10
search app.svc.cluster.local svc.cluster.local cluster.local
```

Resolution order for a query `postgres` from a pod in `app`:

```
1. postgres.app.svc.cluster.local       → not found
2. postgres.svc.cluster.local           → not found
3. postgres.cluster.local               → not found
4. postgres                             → forwarded to upstream
```

---

## Record types CoreDNS returns

| Query type                          | What it returns                                      |
| ----------------------------------- | ---------------------------------------------------- |
| `A` / `AAAA` (ClusterIP Service)    | The Service's ClusterIP                              |
| `A` / `AAAA` (Headless Service)     | All Pod IPs backing the Service, round-robined       |
| `A` / `AAAA` (ExternalName Service) | CNAME to the external hostname                       |
| `SRV`                               | Port + protocol records for named ports on a Service |
| `PTR` (reverse lookup)              | Pod hostname from Pod IP                             |

> **Headless Services** (`clusterIP: None`) have no VIP — CoreDNS returns the individual Pod IPs directly. Used by StatefulSets so each pod gets its own stable DNS name: `pod-0.myapp.namespace.svc.cluster.local`.

**StatefulSet pod DNS example:**

```
StatefulSet: myapp   Namespace: data   Replicas: 3

myapp-0.myapp.data.svc.cluster.local  →  10.42.1.5
myapp-1.myapp.data.svc.cluster.local  →  10.42.2.7
myapp-2.myapp.data.svc.cluster.local  →  10.42.0.3
```

> This is why databases like Kafka, Cassandra, and etcd use StatefulSets — each member must address specific peers by a stable name, not a random ClusterIP.

---

## CoreDNS configuration (Corefile)

CoreDNS is configured by a ConfigMap in `kube-system`. The default k3s Corefile:

```bash
kubectl get configmap coredns -n kube-system -o yaml
```

Default content:

```
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
      pods insecure
      fallthrough in-addr.arpa ip6.arpa
    }
    hosts /etc/coredns/NodeHosts {
      ttl 60
      reload 15s
      fallthrough
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
```

| Directive                      | Role                                                        |
| ------------------------------ | ----------------------------------------------------------- |
| `kubernetes`                   | Handles `.cluster.local` lookups by querying the API server |
| `forward . /etc/resolv.conf`   | Passes all other names upstream to the node's DNS           |
| `cache 30`                     | Caches responses for 30 seconds to reduce upstream load     |
| `hosts /etc/coredns/NodeHosts` | Resolves node hostnames — updated automatically by k3s      |
| `prometheus :9153`             | Exposes DNS metrics for Prometheus scraping                 |
| `loadbalance`                  | Round-robins A records when multiple IPs are returned       |

---

## Customising CoreDNS

Edit the ConfigMap and restart CoreDNS to apply changes.

```bash
kubectl edit configmap coredns -n kube-system
kubectl rollout restart deployment/coredns -n kube-system
```

### Add a custom upstream for a specific domain

Route queries for an internal corporate domain to a private DNS server instead of the node's default resolver:

```
.:53 {
    ...
    forward corp.internal 10.0.0.53
    forward . /etc/resolv.conf
    ...
}
```

> Order matters — CoreDNS evaluates `forward` directives top to bottom and uses the first match.

### Rewrite a hostname

Redirect traffic addressed to a legacy hostname to the real Service name:

```
.:53 {
    ...
    rewrite name legacy-db.app.svc.cluster.local postgres.app.svc.cluster.local
    ...
}
```

### Stub zone — delegate a subdomain to another DNS server

```
old-cluster.internal:53 {
    errors
    forward . 192.168.1.50
}

.:53 {
    ...
}
```

> A stub zone is a separate server block in the Corefile. Queries for `*.old-cluster.internal` go to `192.168.1.50`; all other queries use the main block.

---

## Scaling CoreDNS

CoreDNS runs as a Deployment (default: 1 replica). On clusters with many pods, a single replica can become a bottleneck.

```bash
# Scale to 2 replicas
kubectl scale deployment coredns --replicas=2 -n kube-system
```

> k3s NodeLocal DNSCache is not enabled by default. For clusters with 50+ nodes or high DNS query rates, deploy a NodeLocal DNSCache DaemonSet — it runs a DNS cache on every node so queries never leave the node for cluster names.

---

## Useful commands

```bash
# Check CoreDNS pods are running
kubectl get pods -n kube-system -l k8s-app=coredns

# View CoreDNS logs (all DNS queries if log plugin is enabled)
kubectl logs -n kube-system -l k8s-app=coredns --tail=50

# Test DNS resolution from inside the cluster
kubectl run dns-test --image=alpine --rm -it --restart=Never -- \
  nslookup kubernetes.default.svc.cluster.local

# Test external resolution
kubectl run dns-test --image=alpine --rm -it --restart=Never -- \
  nslookup google.com

# Look up a specific Service
kubectl run dns-test --image=alpine --rm -it --restart=Never -- \
  nslookup <service>.<namespace>.svc.cluster.local

# Check what DNS server a pod is using
kubectl exec -it <pod> -n <namespace> -- cat /etc/resolv.conf

# View CoreDNS metrics (port-forward first)
kubectl port-forward svc/kube-dns 9153:9153 -n kube-system
curl http://localhost:9153/metrics | grep coredns_dns_requests_total
```

---

## Troubleshooting

| Symptom                                | Likely cause                            | Fix                                                                                     |
| -------------------------------------- | --------------------------------------- | --------------------------------------------------------------------------------------- |
| Pod cannot resolve any name            | CoreDNS pod not running                 | `kubectl get pods -n kube-system -l k8s-app=coredns` — restart if not Running           |
| Pod cannot resolve cluster Service     | Wrong namespace in query                | Use full FQDN: `<svc>.<ns>.svc.cluster.local`                                           |
| Pod cannot resolve external names      | Upstream DNS unreachable from node      | Check `/etc/resolv.conf` on the node; verify node has internet access                   |
| Slow DNS responses                     | Single CoreDNS replica under load       | Scale to 2+ replicas; check `cache` TTL in Corefile                                     |
| `NXDOMAIN` for a Service that exists   | Service has no Ready endpoints          | `kubectl get endpoints <svc> -n <ns>` — if empty, pods are not passing readiness checks |
| DNS works for some pods but not others | `hostNetwork: true` pods bypass CoreDNS | Pods with `hostNetwork: true` use the node's `/etc/resolv.conf`, not CoreDNS            |

> **`hostNetwork: true` pods** do not use CoreDNS. They use the node's resolver directly, so cluster Service names do not resolve. Avoid `hostNetwork: true` for pods that need to reach cluster Services. If unavoidable, configure the node's `/etc/resolv.conf` to include `10.43.0.10` as a nameserver.

---

## DNS in the observability stack

Services deployed by this repo and their expected DNS names:

| Service          | DNS name (from within cluster)                  |
| ---------------- | ----------------------------------------------- |
| Grafana          | `grafana.monitoring.svc.cluster.local`          |
| Victoria Metrics | `victoria-metrics.monitoring.svc.cluster.local` |
| Jaeger Query     | `jaeger-query.tracing.svc.cluster.local`        |
| Elasticsearch    | `elasticsearch.logging.svc.cluster.local`       |
| Kafka            | `kafka.streaming.svc.cluster.local`             |
| PostgreSQL       | `postgres.database.svc.cluster.local`           |
| Keycloak         | `keycloak.iam.svc.cluster.local`                |

> Actual names depend on the `metadata.name` and `namespace` set in your Helm values. These are the defaults used by the charts in `helm-charts/`.
