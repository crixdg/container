# k3s Container Runtime

## What is a container

A container is a process running on the host with isolated filesystem, network, and resources. It is not a virtual machine — it shares the host OS kernel but cannot see or affect other processes outside its namespace.

A container is created from an **image** — a read-only bundle of the application binary, libraries, and config. When a container starts, a thin writable layer is added on top of the image. When it stops, that layer is discarded.

**Where a container sits in the k3s system:**

```
User request
    │
    ▼
kubectl / API server          ← control-plane decides what to run
    │
    ▼
Scheduler                     ← picks which node to run it on
    │
    ▼
kubelet (on the chosen node)  ← instructs the runtime to start the container
    │
    ▼
containerd (CRI)              ← pulls the image, creates the container
    │
    ▼
container (running process)   ← your application
```

> A **Pod** is the smallest unit in Kubernetes — it wraps one or more containers that share the same network namespace and storage. When you deploy an app, Kubernetes creates a Pod, and containerd starts the container(s) inside it.

> **Why a Pod can contain multiple containers:**
> Sometimes an application needs a helper process that lives and dies alongside the main container, shares its files or network, but should remain a separate concern. These are called **sidecar containers**. Common patterns:
>
> - **Log shipper** — a second container reads log files written by the main app and forwards them to Elasticsearch or Grafana Loki. The main app does not need to know logs are being shipped.
> - **Proxy / service mesh** — a container like Envoy sits next to the app container, intercepts all inbound and outbound traffic, and adds TLS, retries, and metrics without any code change in the app.
> - **Config reloader** — watches a mounted config file and sends a signal to the main container when it changes, so the app reloads without restarting the Pod.
>
> All containers in a Pod share `localhost` — they communicate over loopback as if they were processes on the same machine. They also share mounted volumes, so one container can write a file and another can read it.
> In most cases a Pod has only one container. Use multiple containers only when the helper is tightly coupled to the main app and must run on the same node.

> **Can a single container restart inside a multi-container Pod?**
> Yes. Each container tracks its own state and restart count independently. If one container crashes, the others keep running — the Pod is not restarted as a whole.
>
> The `restartPolicy` on the Pod (`Always`, `OnFailure`, `Never`) controls whether a crashed container is restarted, but it applies per container, not per Pod.
>
> | Scenario                             | Result                                   |
> | ------------------------------------ | ---------------------------------------- |
> | Sidecar crashes, main app is healthy | Sidecar restarts; main app keeps running |
> | Main app crashes, sidecar is healthy | Main app restarts; sidecar keeps running |
> | Both crash                           | Both restart independently               |
>
> The Pod is only removed and rescheduled if the node itself fails, or if a container keeps crashing and hits the backoff limit (`CrashLoopBackOff`).
>
> To see the restart count of each container in a Pod:
>
> ```bash
> kubectl get pod <pod-name> -o jsonpath='{.status.containerStatuses[*].name} {.status.containerStatuses[*].restartCount}'
> ```

A container runtime is the low-level component that pulls images and starts/stops containers on a node. Kubernetes does not run containers itself — it delegates to the runtime via the **Container Runtime Interface (CRI)**.

## Top choice in production

**containerd** — by a large margin.

Every major managed Kubernetes service defaults to containerd:

| Platform             | Default runtime      |
| -------------------- | -------------------- |
| GKE (Google)         | containerd           |
| EKS (AWS)            | containerd           |
| AKS (Azure)          | containerd           |
| k3s                  | containerd (bundled) |
| kubeadm (bare metal) | containerd           |

> CRI-O is used in OpenShift (Red Hat's enterprise Kubernetes distribution) and in hardened government/defence environments where the smaller attack surface is a compliance requirement.
> For everything else — including this k3s setup — containerd is the correct choice.

---

## Options

### containerd _(default in k3s)_

Built into the k3s binary. No separate install or socket configuration needed.

|        |                                                         |
| ------ | ------------------------------------------------------- |
| Socket | `/run/k3s/containerd/containerd.sock`                   |
| CLI    | `crictl`, `ctr` (bundled with k3s)                      |
| Config | `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` |

**Use this unless you have a specific reason not to.** It is the Kubernetes-recommended runtime, has the lowest overhead, and is maintained by the same project that maintains Kubernetes.

---

### CRI-O

A minimal CRI-only runtime — no image building, no extra tooling. Designed specifically for Kubernetes.

|         |                                                                   |
| ------- | ----------------------------------------------------------------- |
| Socket  | `/var/run/crio/crio.sock`                                         |
| CLI     | `crictl`                                                          |
| Install | Separate package; must match the Kubernetes minor version exactly |

**When to choose:** you want a runtime with a smaller attack surface than containerd and are comfortable managing version alignment manually.

> **Attack surface** refers to every piece of code that an attacker could exploit.
> containerd supports extra features beyond what Kubernetes needs — image building plugins, a gRPC API, snapshot drivers — each one is additional code that could contain vulnerabilities.
> CRI-O implements only the CRI spec and nothing else, so there is less code exposed, fewer open sockets, and fewer binaries on the host.
> On most small production clusters the difference is negligible; it matters mainly in high-security or compliance-driven environments.

**Not the default in k3s** — requires passing `--container-runtime-endpoint` at install time:

```bash
curl -sfL https://get.k3s.io | sh -s - \
  --container-runtime-endpoint unix:///var/run/crio/crio.sock
```

---

### Docker _(not supported in k3s v1.24+)_

Docker was removed as a directly supported runtime in Kubernetes 1.24. k3s never used Docker's CRI socket — it always embedded containerd instead.

> If your workflow requires building images on the node, use `nerdctl` (a Docker-compatible CLI for containerd) rather than installing Docker.

```bash
# nerdctl is a drop-in Docker CLI replacement for containerd
nerdctl build -t myapp:latest .
nerdctl push myapp:latest
```

---

## Comparison

|                     | containerd  | CRI-O                          |
| ------------------- | ----------- | ------------------------------ |
| Bundled with k3s    | Yes         | No                             |
| Extra install       | None        | Required                       |
| Version alignment   | Automatic   | Manual (must match k8s minor)  |
| Attack surface      | Small       | Smaller                        |
| Image build support | Via nerdctl | No                             |
| Recommended for     | All cases   | Security-hardened environments |

---

## Useful commands (containerd)

```bash
# List running containers
crictl ps

# List images
crictl images

# Pull an image manually
crictl pull nginx:alpine

# Inspect a container
crictl inspect <container-id>

# View containerd logs
journalctl -u k3s | grep containerd
```

---

## Private registry (containerd)

To pull from a private registry without `imagePullSecrets`, configure a mirror in `registries.yaml` (see `kubernetes/k3s/registries.yaml`). containerd reads this file at startup — restart k3s after any change.

```bash
# After editing registries.yaml
cp kubernetes/k3s/registries.yaml /etc/rancher/k3s/registries.yaml
systemctl restart k3s
```
