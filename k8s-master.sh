#!/bin/bash
set -e

# ===============================
# Kubernetes Master Setup Script
# Compatible with Ubuntu 22.04 / 24.04
# Installs Kubernetes v1.32.x using binaries
# ===============================

K8S_VERSION="v1.32.8"
CNI_POD_NETWORK="10.244.0.0/16"

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
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
sudo apt-get install -y containerd

# Configure containerd for systemd cgroup
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "[Step 6] Download Kubernetes binaries"
cd /tmp
curl -LO https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl
curl -LO https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubeadm
curl -LO https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubelet

sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
sudo install -o root -g root -m 0755 kubeadm /usr/local/bin/kubeadm
sudo install -o root -g root -m 0755 kubelet /usr/local/bin/kubelet

echo "[Step 7] Create kubelet systemd service"
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
After=network.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable kubelet

echo "[Step 8] Stop kubelet to avoid port conflicts"
sudo systemctl stop kubelet || true

echo "[Step 9] Initialize Kubernetes master node"
sudo kubeadm reset -f || true
sudo kubeadm init --pod-network-cidr=${CNI_POD_NETWORK} | tee kubeadm-init.out

echo "[Step 10] Start kubelet service"
sudo systemctl start kubelet

echo "[Step 11] Configure kubectl for current user"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo "[Step 12] Install Flannel CNI"
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "======================================================"
echo "Master node setup complete!"
echo "Use the following join command on worker nodes:"
grep "kubeadm join" kubeadm-init.out
echo "======================================================"
