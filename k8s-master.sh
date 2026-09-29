#!/bin/bash
# ==============================================================================
# Kubernetes Control-Plane (Master) Installer for Ubuntu 22.04 / 24.04
# Includes containerd, kubeadm, kubelet, kubectl, and Calico CNI
# ==============================================================================

set -euo pipefail

# ---------------- Configuration (override via env vars) ----------------
K8S_MINOR="${K8S_MINOR:-1.32}"                # major.minor track to install, e.g. 1.32
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"        # must match the CNI's expected range
CALICO_VERSION="${CALICO_VERSION:-v3.29.1}"   # pinned Calico release
LOG_FILE="/var/log/k8s-master-install.log"

log()  { echo "[$(date '+%H:%M:%S')] $*" | sudo tee -a "$LOG_FILE" >/dev/null; echo "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

sudo touch "$LOG_FILE"

# ---------------- Preflight checks ----------------
[ "$(id -u)" -eq 0 ] && die "Run this as your normal user with 'sudo bash $0', not as root directly (it needs \$HOME and \$USER set correctly)."
command -v sudo >/dev/null || die "sudo is required."

if ! grep -qE 'Ubuntu 2[24]\.04' /etc/os-release 2>/dev/null; then
  log "WARNING: this script is tested on Ubuntu 22.04/24.04. Continuing anyway on: $(grep PRETTY_NAME /etc/os-release || true)"
fi

if [ -f /etc/kubernetes/admin.conf ]; then
  log "A cluster is already initialized on this node (/etc/kubernetes/admin.conf exists)."
  log "Skipping kubeadm init and re-applying CNI/kubeconfig steps only."
  SKIP_INIT=true
else
  SKIP_INIT=false
fi

log "[Step 1] Update system"
sudo apt-get update -y
sudo apt-get upgrade -y

log "[Step 2] Disable swap"
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

log "[Step 3] Load kernel modules"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

log "[Step 4] Set sysctl parameters for Kubernetes networking"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system >/dev/null

log "[Step 5] Install containerd"
sudo apt-get install -y containerd

log "[Step 6] Configure containerd for systemd cgroups"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

log "[Step 7] Add Kubernetes APT repository (${K8S_MINOR} track)"
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

log "[Step 8] Detect latest ${K8S_MINOR}.x patch release"
sudo apt-get update -y
FULL_VERSION=$(apt-cache madison kubeadm | awk '{print $3}' | grep "^${K8S_MINOR}" | sort -V | tail -1)
[ -n "$FULL_VERSION" ] || die "Could not find a kubeadm package for ${K8S_MINOR} in the configured repo."
K8S_VERSION="${FULL_VERSION%%-*}"   # strip the Debian package revision, e.g. "1.32.5-1.1" -> "1.32.5"
log "Installing Kubernetes ${K8S_VERSION} (package ${FULL_VERSION})"

log "[Step 9] Install kubelet, kubeadm, kubectl"
sudo apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
sudo apt-get install -y kubelet="${FULL_VERSION}" kubeadm="${FULL_VERSION}" kubectl="${FULL_VERSION}"
sudo apt-mark hold kubelet kubeadm kubectl

log "[Step 10] Configure kubelet to use systemd cgroup with containerd"
sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf >/dev/null
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
sudo systemctl daemon-reload
sudo systemctl restart kubelet

if [ "$SKIP_INIT" = false ]; then
  log "[Step 11] Initialize Kubernetes control plane"
  sudo kubeadm init --pod-network-cidr="${POD_CIDR}" --kubernetes-version="v${K8S_VERSION}" | tee kubeadm-init.out
  grep "kubeadm join" -A1 kubeadm-init.out > join-command.sh || true
  log "Join command saved to $(pwd)/join-command.sh"
fi

log "[Step 12] Configure kubectl for current user"
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

log "[Step 13] Wait for the API server to respond"
export KUBECONFIG="$HOME/.kube/config"
timeout 180 bash -c 'until kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 3; done' \
  || die "API server did not become ready within 180s. Check: sudo journalctl -u kubelet -n 100"
log "API server is ready."

log "[Step 14] Install Calico CNI (${CALICO_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

log "[Step 15] Wait for this node and Calico to become Ready"
timeout 300 bash -c 'until kubectl get nodes --no-headers 2>/dev/null | awk "{print \$2}" | grep -q "^Ready\$\|,Ready\$"; do sleep 5; done' \
  || log "WARNING: node did not report Ready within 300s -- check 'kubectl get pods -n kube-system' manually."
kubectl -n kube-system rollout status daemonset/calico-node --timeout=180s \
  || log "WARNING: calico-node daemonset did not finish rolling out -- check 'kubectl -n kube-system get pods -l k8s-app=calico-node'."

echo "======================================================"
echo "Master node setup complete!"
if [ -f join-command.sh ]; then
  echo "Join command for worker nodes (also saved to join-command.sh):"
  cat join-command.sh
else
  echo "Cluster was already initialized; run 'kubeadm token create --print-join-command' to get a fresh join command."
fi
echo "Verify with: kubectl get nodes"
echo "Full install log: $LOG_FILE"
echo "======================================================"
