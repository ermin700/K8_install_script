# Kubernetes Cluster Installer for Ubuntu 22.04 / 24.04

This repository contains two Bash scripts to automate the setup of a Kubernetes cluster using `kubeadm`. `k8s-master.sh` sets up the single control-plane node; `k8s-worker.sh` is run on however many worker nodes you want and joins each one to that control plane.

## Features

- **Automated setup** of containerd, kubeadm, kubelet, kubectl and Calico CNI.
- **Modern runtime**: containerd with the systemd cgroup driver.
- **Auto-detected patch version**: both scripts install the latest patch release of a configurable major.minor track (`K8S_MINOR`, default `1.37` — the latest stable release as of writing) instead of a hardcoded version, so the control plane and workers always end up on matching, currently-available packages. Bump `K8S_MINOR` as new Kubernetes minors ship; the scripts don't need any other changes to track a new release.
- **Idempotent-ish re-runs**: re-running `k8s-master.sh` on an already-initialized node skips `kubeadm init` instead of failing; `k8s-worker.sh` resets any previous join before trying again.
- **Preflight checks**: worker script verifies it can actually reach the control plane's API port before spending minutes installing packages, and rejects an unedited join-command placeholder with a clear error instead of a cryptic TLS failure.
- **Logging**: every run appends to `/var/log/k8s-master-install.log` or `/var/log/k8s-worker-install.log`.

## Prerequisites

- Two or more Ubuntu 22.04/24.04 servers or VMs.
- `sudo` privileges on all machines.
- A stable internet connection.
- If these are real servers/cloud VMs (not local VMs on the same host-only network), make sure your firewall/security group allows at minimum:
  - **Control plane**: TCP 6443 (API server) from workers and your workstation; TCP 2379-2380, 10250-10259 between cluster nodes only.
  - **Workers**: TCP 10250 from the control plane; TCP 30000-32767 if you expose NodePort services.

## Usage

### Step 1: Set up the control-plane node

Copy `k8s-master.sh` to the node and run it:

```bash
sudo bash k8s-master.sh
```

Optional overrides via environment variables:

```bash
K8S_MINOR=1.36 POD_CIDR=10.244.0.0/16 CALICO_VERSION=v3.29.1 sudo -E bash k8s-master.sh
```

When it finishes it prints (and saves to `join-command.sh` next to the script) the `kubeadm join` command you'll need for Step 2.

### Step 2: Set up each worker node

Copy `k8s-worker.sh` to the worker. Open it and replace the placeholder:

```bash
KUBEADM_JOIN_COMMAND="PASTE_YOUR_KUBEADM_JOIN_COMMAND_HERE"
```

with the full command from `join-command.sh` on the master, e.g.:

```bash
KUBEADM_JOIN_COMMAND="kubeadm join 10.0.0.10:6443 --token abcdef.0123456789abcdef --discovery-token-ca-cert-hash sha256:deadbeef..."
```

Save the file, then run:

```bash
sudo bash k8s-worker.sh
```

If `K8S_MINOR` was overridden on the master, set the same value here so both sides install matching versions.

### Verification

From the control-plane node:

```bash
kubectl get nodes
```

You should see the master and each worker listed with `STATUS Ready` (Calico needs a minute or two after a worker joins before it reports Ready).

## Troubleshooting

- **Forgot to edit the join command**: the worker script now checks for the placeholder text and any leftover `<token>`/`<hash>` markers and exits with a clear message instead of silently running a broken command.
- **Worker can't reach the master**: the script resolves the host:port from the join command and does a TCP connectivity check before installing anything. If that fails, check firewall/security group rules and that the address is actually reachable from the worker.
- **Node stuck `NotReady`**: usually Calico hasn't finished rolling out yet. Check with `kubectl -n kube-system get pods -l k8s-app=calico-node`.
- **Re-running after a failure**: `k8s-master.sh` detects an existing `/etc/kubernetes/admin.conf` and skips `kubeadm init`; `k8s-worker.sh` always runs `kubeadm reset` first, so it's safe to re-run either script.
- **Version mismatches**: both scripts install the latest patch of the same `K8S_MINOR` track by default, so they should always agree. If you pin different `K8S_MINOR` values on master vs. workers you may hit skew issues — keep them in sync.

## Staying current

The default `K8S_MINOR` (`1.37`) and `CALICO_VERSION` (`v3.32.2`) are the latest stable releases as of writing. To check what's newer without editing anything:

```bash
# Latest Kubernetes minor tracks Google's repo actually serves
curl -s https://pkgs.k8s.io/core:/stable:/v1.38/deb/Release   # 403 = not published yet

# Latest Calico release tag
curl -s https://api.github.com/repos/projectcalico/calico/releases/latest | grep tag_name
```

Kubernetes only supports upgrading one minor version at a time via `kubeadm upgrade`, so for an existing cluster don't just bump `K8S_MINOR` and re-run — follow the [official kubeadm upgrade docs](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/) instead. These scripts are for fresh installs.
