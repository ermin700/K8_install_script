#!/bin/bash
# ==============================================================================
# Kubernetes Worker Node Installer for Ubuntu 22.04 / 24.04
# Includes containerd, kubeadm, kubelet, kubectl
# Handles partial installs and safely (re)joins a cluster
# Automatically installs the latest patch release of the configured minor track
# ==============================================================================

set -euo pipefail

# ---------------- Configuration (override via env vars) ----------------
K8S_MINOR="${K8S_MINOR:-1.37}"   # major.minor track to install (latest stable as of writing) -- must match the master
LOG_FILE="/var/log/k8s-worker-install.log"

# --- IMPORTANT ---
# Paste the full 'kubeadm join ...' command printed by k8s-master.sh below.
KUBEADM_JOIN_COMMAND="PASTE_YOUR_KUBEADM_JOIN_COMMAND_HERE"

log()  { echo "[$(date '+%H:%M:%S')] $*" | sudo tee -a "$LOG_FILE" >/dev/null; echo "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

sudo touch "$LOG_FILE"

# ---------------- Preflight checks ----------------
[ "$(id -u)" -eq 0 ] && die "Run this as your normal user with 'sudo bash $0', not as root directly."
command -v sudo >/dev/null || die "sudo is required."

case "$KUBEADM_JOIN_COMMAND" in
  *PASTE_YOUR_KUBEADM_JOIN_COMMAND_HERE*|*"<token>"*|""|*"kubeadm join <"* )
    die "Edit this script and replace KUBEADM_JOIN_COMMAND with the real join command from k8s-master.sh (see join-command.sh on the master, or run 'kubeadm token create --print-join-command' there)."
    ;;
esac
[[ "$KUBEADM_JOIN_COMMAND" == kubeadm\ join* ]] || die "KUBEADM_JOIN_COMMAND must start with 'kubeadm join'. Got: $KUBEADM_JOIN_COMMAND"

if ! grep -qE 'Ubuntu 2[24]\.04' /etc/os-release 2>/dev/null; then
  log "WARNING: this script is tested on Ubuntu 22.04/24.04. Continuing anyway on: $(grep PRETTY_NAME /etc/os-release || true)"
fi

# Pull the master's host:port out of the join command and sanity-check reachability
# before we spend minutes installing packages just to fail on the actual join.
MASTER_ADDR=$(echo "$KUBEADM_JOIN_COMMAND" | grep -oE '[0-9a-zA-Z.-]+:[0-9]+' | head -1 || true)
if [ -n "$MASTER_ADDR" ]; then
  MASTER_HOST="${MASTER_ADDR%%:*}"
  MASTER_PORT="${MASTER_ADDR##*:}"
  log "[Preflight] Checking connectivity to control plane at ${MASTER_ADDR}"
  if ! timeout 5 bash -c "cat < /dev/null > /dev/tcp/${MASTER_HOST}/${MASTER_PORT}" 2>/dev/null; then
    die "Cannot reach ${MASTER_ADDR} on TCP/${MASTER_PORT}. Check the master's firewall/security group allows this port, and that the address is correct."
  fi
else
  log "WARNING: could not parse master host:port out of the join command; skipping connectivity preflight."
fi

# ---------------- Cleanup any leftovers ----------------
log "[Step 0] Reset any previous Kubernetes installation on this node"
sudo kubeadm reset -f >/dev/null 2>&1 || true
sudo systemctl stop kubelet 2>/dev/null || true
sudo rm -rf /etc/kubernetes/manifests/* "$HOME/.kube"

# ---------------- System Preparation ----------------
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

# ---------------- Install containerd ----------------
log "[Step 5] Install containerd"
sudo apt-get install -y containerd

log "[Step 6] Configure containerd for systemd cgroups"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# ---------------- Add Kubernetes repo ----------------
log "[Step 7] Add Kubernetes APT repository (${K8S_MINOR} track)"
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

# ---------------- Detect latest patch version ----------------
log "[Step 8] Detecting latest Kubernetes ${K8S_MINOR} version"
sudo apt-get update -y
FULL_VERSION=$(apt-cache madison kubeadm | awk '{print $3}' | grep "^${K8S_MINOR}" | sort -V | tail -1)
[ -n "$FULL_VERSION" ] || die "Could not detect latest Kubernetes ${K8S_MINOR} version from repo."
log "Latest Kubernetes version detected: $FULL_VERSION"

# ---------------- Install Kubernetes components ----------------
log "[Step 9] Install kubelet, kubeadm, kubectl"
sudo apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
sudo apt-get install -y kubelet="${FULL_VERSION}" kubeadm="${FULL_VERSION}" kubectl="${FULL_VERSION}"
sudo apt-mark hold kubelet kubeadm kubectl

# ---------------- Configure kubelet ----------------
log "[Step 10] Configure kubelet for systemd cgroups with containerd"
sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf >/dev/null
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now kubelet

# ---------------- Join cluster ----------------
log "[Step 11] Join the Kubernetes cluster"
# shellcheck disable=SC2086
sudo $KUBEADM_JOIN_COMMAND

log "[Step 12] Confirm kubelet is active"
sudo systemctl is-active --quiet kubelet && log "kubelet is running." \
  || log "WARNING: kubelet is not active -- check 'sudo journalctl -u kubelet -n 100'."

echo "======================================================"
echo "Worker node setup complete!"
echo "From the master node, check status with: kubectl get nodes"
echo "Full install log: $LOG_FILE"
echo "======================================================"
