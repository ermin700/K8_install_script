#!/bin/bash
# ==============================================================================
# Kubernetes 1.32 Worker Node Installer for Ubuntu 22.04
# Includes containerd, kubeadm, kubelet, kubectl
# Handles partial installs and safely joins master
# Automatically installs the latest patch release of 1.32.x
# ==============================================================================

set -euo pipefail

# ---------------- Configuration ----------------
K8S_MAJOR_MINOR="1.32"

# --- IMPORTANT ---
# Paste the 'kubeadm join' command from your master node below
KUBEADM_JOIN_COMMAND="kubeadm join 10.0.0.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"

if [ -z "$KUBEADM_JOIN_COMMAND" ]; then
    echo "Error: Please set the KUBEADM_JOIN_COMMAND variable with your master node join command."
    exit 1
fi

# ---------------- Cleanup any leftovers ----------------
echo "[Step 0] Reset any previous Kubernetes installation"
sudo kubeadm reset -f || true
sudo systemctl stop kubelet || true
sudo systemctl disable kubelet || true
sudo rm -rf /etc/kubernetes/manifests/* $HOME/.kube

# ---------------- System Preparation ----------------
echo "[Step 1] Update system"
sudo apt-get update -y
sudo apt-get upgrade -y

echo "[Step 2] Disable swap"
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "[Step 3] Load kernel modules"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

echo "[Step 4] Set sysctl parameters for Kubernetes networking"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# ---------------- Install containerd ----------------
echo "[Step 5] Install containerd"
sudo apt-get install -y containerd

echo "[Step 6] Configure containerd for systemd cgroups"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# ---------------- Add Kubernetes repo ----------------
echo "[Step 7] Add Kubernetes APT repository"
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

# ---------------- Detect latest patch version ----------------
echo "[Step 8] Detecting latest Kubernetes ${K8S_MAJOR_MINOR} version..."
sudo apt-get update -y
LATEST_VERSION=$(apt-cache madison kubeadm | awk '{print $3}' | grep "^${K8S_MAJOR_MINOR}" | sort -V | tail -1)

if [ -z "$LATEST_VERSION" ]; then
    echo "Error: Could not detect latest Kubernetes ${K8S_MAJOR_MINOR} version from repo"
    exit 1
fi

echo "Latest Kubernetes version detected: $LATEST_VERSION"

# ---------------- Install Kubernetes components ----------------
echo "[Step 9] Install kubelet, kubeadm, kubectl"
sudo apt-get install -y kubelet="${LATEST_VERSION}" kubeadm="${LATEST_VERSION}" kubectl="${LATEST_VERSION}"
sudo apt-mark hold kubelet kubeadm kubectl

# ---------------- Configure kubelet ----------------
echo "[Step 10] Configure kubelet for systemd cgroups with containerd"
sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now kubelet

# ---------------- Join cluster ----------------
echo "[Step 11] Join the Kubernetes cluster"
sudo $KUBEADM_JOIN_COMMAND

echo "======================================================"
echo "Worker node setup complete!"
echo "Check node status from master: kubectl get nodes"
echo "======================================================"
