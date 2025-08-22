Kubernetes Cluster Setup on Ubuntu 22.04
This repository provides automation scripts to set up a vanilla Kubernetes cluster (using kubeadm) on Ubuntu 22.04.It includes setup for both control-plane (master) nodes and worker nodes.

Prerequisites
	•	Ubuntu 22.04 server(s) with internet access
	•	At least 2 GB RAM and 2 vCPUs per node (recommended)
	•	All nodes should have:
	◦	Unique hostname
	◦	Static IP or DHCP reservation
	◦	Passwordless SSH (optional, for easier management)
	•	Ports open (if firewall is enabled):
	◦	Master: 6443, 2379-2380, 10250, 10259, 10257
	◦	Workers: 10250, 30000-32767

Steps
1. Clone or copy the scripts

git clone https://github.com/ermin700/k8s-setup.git
cd k8s-setup
chmod +x k8s-master.sh k8s-worker.sh

2. Set up the Control-plane (Master) node
Run the following script on your master node:

./k8s-master.sh
This will:
	•	Update system packages
	•	Disable swap
	•	Configure kernel modules and sysctl
	•	Install containerd (runtime)
	•	Install kubeadm, kubelet, kubectl
	•	Initialize the Kubernetes control-plane
	•	Install the Flannel CNI plugin
At the end, it will display a kubeadm join command, for example:

kubeadm join 192.168.1.100:6443 --token abc123 \
    --discovery-token-ca-cert-hash sha256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Save this command — you will need it for the worker nodes.

3. Set up the Worker node(s)
Run the following script on each worker node:

./k8s-worker.sh
After it completes, paste in the kubeadm join ... command from the master node output.

4. Verify the cluster
On the master node, run:

kubectl get nodes
You should see your master and all worker nodes in the Ready state.

CNI Plugin
This setup uses Flannel for networking.If you prefer another CNI (like Calico), skip the Flannel installation in k8s-master.sh and apply the manifest for your chosen CNI.

Resetting the cluster (if needed)
If you need to reset everything and start over:

sudo kubeadm reset -f
sudo systemctl restart containerd
sudo systemctl restart kubelet
Remove the Kubernetes configs:

rm -rf $HOME/.kube
Then re-run the scripts.

Summary
	•	Run k8s-master.sh on the control-plane node
	•	Run k8s-worker.sh on each worker node
	•	Join workers using the command printed by the master
	•	Verify with kubectl get nodes
You now have a working Kubernetes cluster on Ubuntu 22.04 🚀
