Kubernetes 1.32.1 Cluster Installer for Ubuntu 22.04
This repository contains two Bash scripts to automate the setup of a Kubernetes cluster using kubeadm on Ubuntu 22.04. The scripts handle the installation of containerd, kubeadm, kubelet, and kubectl, and configure the network with Calico CNI.

Features
Automated Setup: Installs all necessary components for a Kubernetes master and worker node.

Modern Runtime: Uses containerd as the container runtime.

Version Control: Installs Kubernetes version 1.32.1 and holds the packages to prevent unwanted upgrades.

Calico CNI: Installs Calico to provide pod-to-pod networking.

Prerequisites
Two or more Ubuntu 22.04 servers or virtual machines.

sudo privileges on all machines.

A stable internet connection.

Usage
Follow these steps in order to set up your Kubernetes cluster.

Step 1: Set up the Master Node
The k8s-master.sh script prepares the master node, initializes the cluster, and installs the Calico CNI.

Copy the k8s-master.sh script to your master node.

Open a terminal and run the script with sudo privileges:

sudo bash k8s-master.sh

The script will take a few minutes to complete. When it finishes, it will print a kubeadm join command. You must copy this command for use in the next step.

Step 2: Set up the Worker Node
The k8s-worker.sh script prepares the worker node to join the cluster.

Copy the k8s-worker.sh script to your worker node(s).

Edit the script and replace the PASTE_YOUR_KUBEADM_JOIN_COMMAND_HERE placeholder with the kubeadm join command you copied from the master node.

Save the changes.

Open a terminal and run the script with sudo privileges:

sudo bash k8s-worker.sh

Wait a few minutes for the script to finish. It will join the worker node to the cluster.

Verification
On your master node, you can verify that the worker node has successfully joined by running the following command:

kubectl get nodes

You should see both your master node and your new worker node listed with a STATUS of Ready.

Troubleshooting
The initial issue you faced was due to an outdated APT repository URL for Kubernetes packages. Both scripts have been updated to use the correct repository, ensuring that the packages for version 1.32.1 are found and installed correctly.