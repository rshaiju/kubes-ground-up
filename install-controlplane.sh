#!/bin/bash
HOST_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
HOST_NAME=$(hostname)
STAGING_FOLDER="/tmp/install-controlplane"
KUBERNETES_PKI_FOLDER="/etc/kubernetes/pki"

exec 3>&1

function say(){
	printf "%b\n" "Info:$1" >&3
}	

function say_err(){
	if [ -t 1 ] && command -v tput >/dev/null
	then       	
		RED='\033[0;31m'
		NC='\033[0m'
	fi

	printf "%b\n" "${RED:-}Error:$1${NC:-}" >&2
}

sudo rm -r $STAGING_FOLDER 2>/dev/null

say "Created staging folder"
mkdir $STAGING_FOLDER

say "Installing kubectl.."
bash install-kubectl.sh
say "Installed kubectl"

say "Creating root certificate"
bash create-root-certificate.sh
say "Created root certificate"

sudo cp $KUBERNETES_PKI_FOLDER/ca.* $STAGING_FOLDER

say "Installing etcd"
bash install-etcd.sh --ca-key=$STAGING_FOLDER/ca.key --ca-crt=$STAGING_FOLDER/ca.crt
say "Installed etcd"

say "Installing kube-apiserver"
bash install-kube-apiserver.sh --ca-key=$STAGING_FOLDER/ca.key --ca-crt=$STAGING_FOLDER/ca.crt
say "Installed- kube-apiserver"

say "Creating admin config"
bash create-admin-kubeconfig.sh --ca-key=$STAGING_FOLDER/ca.key --ca-crt=$STAGING_FOLDER/ca.crt --api-server=$HOST_IP
say "Created admin config"

say "Installing kube-controller-manager"
bash install-kube-controller-manager.sh --ca-key=$STAGING_FOLDER/ca.key --ca-crt=$STAGING_FOLDER/ca.crt --api-server=$HOST_IP
say "Installed kube-controller-manager"

say "Installing kube-scheduler"
bash install-kube-scheduler.sh --ca-key=$STAGING_FOLDER/ca.key --ca-crt=$STAGING_FOLDER/ca.crt --api-server=$HOST_IP
say "Installed kube-scheduler"

say "Removing staging folder"
sudo rm -r $STAGING_FOLDER

say "Installed all control plane components"


