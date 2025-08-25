#!/bin/bash
# ==============================================================================
# Kubernetes 1.32.1 Master Node Installer for Ubuntu 22.04
# Includes containerd, kubeadm, kubelet, kubectl, and Calico CNI
# ==============================================================================

set -euo pipefail

# Configuration
K8S_VERSION="1.32.1"
CNI_POD_NETWORK="192.168.0.0/16"

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

echo "[Step 5] Install containerd"
sudo apt-get install -y containerd

echo "[Step 6] Configure containerd for systemd cgroups"
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "[Step 7] Add Kubernetes APT repository"
# The previous repository is outdated. The correct one is now maintained
# with an official key and a different URL.
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION:0:4}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION:0:4}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "[Step 8] Install kubelet, kubeadm, kubectl"
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "[Step 9] Configure kubelet to use systemd cgroup with containerd"
sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
sudo systemctl daemon-reload
sudo systemctl restart kubelet

echo "[Step 10] Initialize Kubernetes master node"
sudo kubeadm init --pod-network-cidr=${CNI_POD_NETWORK} --kubernetes-version="v${K8S_VERSION}" | tee kubeadm-init.out

echo "[Step 11] Configure kubectl for current user"
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$USER:$USER" "$HOME/.kube/config"

echo "[Step 12] Wait for control-plane pods to be ready"
for i in {1..40}; do
  if kubectl get pods -n kube-system 2>/dev/null | grep -E 'kube-apiserver|kube-controller-manager|kube-scheduler' | grep -vq 'Running'; then
    echo "Waiting for control-plane pods... ($i/40)"
    sleep 6
  else
    echo "Control-plane pods are running!"
    break
  fi
done

echo "[Step 13] Install Calico CNI"
kubectl apply -f https://projectcalico.docs.tigera.io/manifests/calico.yaml

echo "======================================================"
echo "Master node setup complete!"
echo "Use the following join command on worker nodes:"
grep "kubeadm join" kubeadm-init.out
echo "======================================================"