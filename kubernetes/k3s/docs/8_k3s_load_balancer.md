# k3s Load Balancer

A load balancer distributes incoming traffic across multiple nodes or pods. In Kubernetes, "load balancer" refers to two distinct things that are often confused:

| Term                           | What it is                                                                       |
| ------------------------------ | -------------------------------------------------------------------------------- |
| **Service type: LoadBalancer** | A Kubernetes Service that requests an external IP from the cluster's LB provider |
| **Ingress controller**         | An application-layer (L7) proxy that routes HTTP/HTTPS by hostname and path      |

This doc covers the Service-level load balancer. For HTTP routing see `7_k3s_ingress.md`.

---

## Service type: LoadBalancer

When you create a Service with `type: LoadBalancer`, Kubernetes asks the cluster's load balancer controller to provision an external IP for it. On cloud providers (AWS, GCP, Azure) this creates a cloud load balancer automatically. On bare metal there is no cloud — you need an in-cluster controller to handle it.

```
Service type: LoadBalancer
    │
    ▼
LB controller assigns external IP
    │
    ▼
Traffic to that IP → forwarded to the Service's pods
```

Without a LB controller, the Service stays in `<pending>` external IP state forever:

```bash
kubectl get svc
NAME       TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)
my-svc     LoadBalancer   10.43.1.5     <pending>     80:31234/TCP
```

---

## k3s default: ServiceLB (disabled in this repo)

k3s ships with a built-in load balancer called **ServiceLB** (formerly Klipper LB). It assigns a node's IP as the external IP for any `LoadBalancer` Service and forwards traffic via iptables.

This repo disables ServiceLB (`--disable servicelb` in `install-server.sh`) because:

- ingress-nginx with `hostNetwork: true` handles all external HTTP/HTTPS traffic directly — no LoadBalancer Service needed
- ServiceLB conflicts with ingress-nginx on ports 80/443 when both try to bind the same node ports

> If you re-enable ServiceLB, remove `--disable servicelb` from `install-server.sh` and reprovision the server node.

---

## Options for bare metal

### ingress-nginx with hostNetwork _(this repo's approach)_

Not a LoadBalancer controller — but for HTTP/HTTPS workloads it replaces the need for one entirely. The NGINX pod binds directly to ports 80/443 on the ingress node's physical NIC. External traffic hits the node IP directly.

```
External IP = ingress node's IP address (static, no LB controller needed)

DNS: myapp.example.com → 192.168.1.100 (ingress node)
                              │
                         NGINX on :443
                              │
                         Backend Service
```

**Suitable for:** all HTTP/HTTPS services. Not suitable for raw TCP/UDP services (databases, MQTT, game servers) that cannot be fronted by an HTTP proxy.

---

### MetalLB _(bare metal LB controller)_

MetalLB is the standard bare metal load balancer for Kubernetes. It watches for `LoadBalancer` Services and assigns IPs from a configured pool. Two modes:

**L2 mode** — MetalLB announces the IP via ARP on the local network. One node "owns" the IP at a time and acts as the gateway for it. Simple to set up, no router config needed.

**BGP mode** — MetalLB peers with your router via BGP and advertises the IP. Traffic is distributed at the router level across all nodes. Requires a BGP-capable router.

```
L2 mode:                          BGP mode:
─────────                         ─────────
MetalLB picks leader node         MetalLB peers with router
ARP: "192.168.1.200 is at         Router balances across all nodes
      node-01's MAC"              True ECMP load distribution
Traffic → node-01 → pod           Traffic → any node → pod
```

MetalLB is not in this repo — install if you need `LoadBalancer` Services for non-HTTP workloads:

```bash
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb -n metallb-system --create-namespace

# Configure an IP pool (L2 mode example)
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.200-192.168.1.210   # range of IPs MetalLB can assign
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
EOF
```

After install, `LoadBalancer` Services get an IP from the pool:

```bash
kubectl get svc
NAME       TYPE           CLUSTER-IP    EXTERNAL-IP     PORT(S)
my-svc     LoadBalancer   10.43.1.5     192.168.1.200   5432:31234/TCP
```

---

### Cilium BGP _(advanced, router integration)_

Cilium has a built-in BGP control plane that can advertise `LoadBalancer` Service IPs directly to your router — no MetalLB needed. This repo has a BGP peering policy at `kubernetes/essential/cilium/__bgp_policy.yaml` but it is marked as not yet working.

```yaml
# kubernetes/essential/cilium/__bgp_policy.yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumBGPPeeringPolicy
metadata:
  name: bgp-peering
spec:
  nodeSelector:
    matchLabels:
      bgp-ready: "true"
  virtualRouters:
    - localASN: 64512
      serviceSelector:
        matchExpressions:
          - key: "kubernetes.io/service-type"
            operator: In
            values:
              - LoadBalancer
      neighbors:
        - peerAddress: 192.0.2.1/32
          peerASN: 64513
```

Label nodes to enable BGP peering:

```bash
kubectl label node <node-name> bgp-ready=true
```

**When to choose:** you have a BGP-capable router and want to eliminate MetalLB as a separate component. Requires Cilium as CNI (see `3_k3s_pod_networking.md`).

---

### HAProxy _(L4/L7 external LB, optional)_

This repo includes an optional HAProxy deployment at `kubernetes/temp/haproxy/`. HAProxy runs inside the cluster as a pod and can front multiple backend services at the TCP or HTTP level.

```
External traffic
    │
    ▼
HAProxy pod (LoadBalancer or NodePort Service)
    │
    ├── :80 → backend be_main
    └── :443 → backend be_ssl
```

Install (after filling in `kubernetes/temp/haproxy/values.yaml`):

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install haproxy bitnami/haproxy \
  -f kubernetes/temp/haproxy/values.yaml \
  -n haproxy --create-namespace
```

> HAProxy in-cluster requires either MetalLB (to get an external IP for its Service) or a NodePort to be reachable from outside. Without MetalLB, its `type: LoadBalancer` Service will stay `<pending>`. For most k3s setups, ingress-nginx already covers what HAProxy would do.

---

## Comparison

|                        | ServiceLB (k3s built-in) | ingress-nginx hostNetwork | MetalLB             | Cilium BGP                  | HAProxy             |
| ---------------------- | ------------------------ | ------------------------- | ------------------- | --------------------------- | ------------------- |
| Protocol               | TCP/UDP                  | HTTP/HTTPS only           | TCP/UDP + HTTP      | TCP/UDP + HTTP              | TCP/UDP + HTTP      |
| Requires router config | No                       | No                        | No (L2) / Yes (BGP) | Yes                         | No                  |
| External IP source     | Node IP                  | Node IP                   | Configured pool     | BGP-advertised              | NodePort or MetalLB |
| In this repo           | Disabled                 | Used (default)            | Not installed       | Config exists (not working) | Optional (`temp/`)  |
| Best for               | Simple single-node       | HTTP/HTTPS workloads      | Non-HTTP services   | BGP router environments     | Advanced L4 routing |

---

## When you actually need a LoadBalancer Service

Most services in this repo (Grafana, Kibana, AKHQ, Prometheus) are HTTP — they go through ingress-nginx and never need a `LoadBalancer` Service. You only need one when:

- **Non-HTTP protocols** — PostgreSQL (5432), Kafka (9092), Redis (6379) that must be reachable from outside the cluster directly
- **External database access** — a client outside the cluster needs to connect to a database pod
- **Game servers, MQTT brokers, gRPC services** that cannot be fronted by an HTTP proxy

For everything else, `ClusterIP` + Ingress is sufficient.

---

## Useful commands

```bash
# Check if any Service is stuck Pending external IP
kubectl get svc -A | grep "<pending>"

# Check which LB controller is running
kubectl get pods -A | grep -E "metallb|servicelb|cilium-operator"

# Check MetalLB IP address pools
kubectl get ipaddresspool -n metallb-system

# Check which Service got which external IP
kubectl get svc -A -o wide | grep LoadBalancer

# Describe a pending LoadBalancer Service to see why
kubectl describe svc <name> -n <namespace>
# Events section will indicate if no LB controller is available
```

---

## Troubleshooting

| Symptom                                 | Cause                                                  | Fix                                                                                     |
| --------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| `EXTERNAL-IP` stuck `<pending>`         | No LB controller running                               | Install MetalLB, or re-enable ServiceLB, or switch to NodePort                          |
| MetalLB installed but IP not assigned   | IP pool exhausted or not configured                    | `kubectl get ipaddresspool -n metallb-system` — check pool has free IPs                 |
| Two services fighting for the same port | ServiceLB and ingress-nginx both trying to bind 80/443 | Ensure ServiceLB is disabled: check `--disable servicelb` in k3s server flags           |
| Cilium BGP peering not establishing     | Router ASN or peer address wrong in policy             | Check `CiliumBGPPeeringPolicy` — verify `peerAddress` and `peerASN` match router config |
| HAProxy Service stuck `<pending>`       | No MetalLB to assign external IP                       | Add MetalLB, or change HAProxy Service to `type: NodePort`                              |
