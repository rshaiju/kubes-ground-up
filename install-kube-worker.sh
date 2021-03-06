#!/bin/bash
HOST_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
HOST_NAME=$(hostname)
STAGING_FOLDER="/tmp/install-kube-worker"
KUBERNETES_PKI_FOLDER="/etc/kubernetes/pki"

install_network_addon=false

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

function validate_args(){
	if [ -z $ca_key ]
	then
		say_err "--ca-key must be provided"
		exit 1
	fi	

	if [ ! -e $ca_key ]
	then
		say_err "CA Key file $ca_key does not exist"
		exit 1
	fi	

	if [ -z $ca_crt ]
	then
		say_err "--ca-crt must be provided"
		exit
	fi

	if [ ! -e $ca_crt ]
	then
		say_err "CA certificate file $ca_crt does not exist"
		exit 1
	fi

	if [ -z $api_server ]
	then
		say_err "--api-server must be provided"
		exit 1
	fi	
}	

while [ "$#" -gt 0 ]
do

case "$1" in
		--ca-key=*)
			ca_key="${1#*=}"
			shift 1;
			;;
		--ca-crt=*)
		        ca_crt="${1#*=}"	
			shift 1;
			;;
		--api-server=*)
			api_server="${1#*=}"
			shift 1;
			;;
		--install-network-addon)
			install_network_addon=true
			shift 1;
			;;
		--help)
			say "Installs Kubernetes Worker Components"
			say "Usage:"
			say "\t $scipt_name --ca-key <PATH TO CA KEY FILE> --ca-crt <PATH TO CA CRT FILE> [Options]" 
			say "Options:"
			say "\t--install-network-addon\tInstalls Weavenet network addon"
			exit 0
			;;
		*)
			say_err "Uknown option $1"
			exit 1;
			;;
	esac
done

validate_args

sudo rm -r $STAGING_FOLDER 2>/dev/null

say "Creatng staging folder"
sudo mkdir $STAGING_FOLDER

say "Creating Kubernetes pki folder"
sudo mkdir $KUBERNETES_PKI_FOLDER -p

sudo cp $ca_key $ca_crt $KUBERNETES_PKI_FOLDER

say "Installing kubectl.."
bash install-kubectl.sh
say "Installed kubectl"

sudo cp $KUBERNETES_PKI_FOLDER/ca.* $STAGING_FOLDER

say "Creating admin config"
bash create-admin-kubeconfig.sh --ca-key=$STAGING_FOLDER/ca.key --ca-crt=$STAGING_FOLDER/ca.crt --api-server=$api_server
say "Created admin config"

say "Installing kubelet"
bash install-kubelet.sh --ca-key=$STAGING_FOLDER/ca.key --ca-crt=$STAGING_FOLDER/ca.crt --api-server=$api_server
say "Installed kubelet"

say "Installing kube-proxy"
bash install-kube-proxy.sh --ca-key=$STAGING_FOLDER/ca.key --ca-crt=$STAGING_FOLDER/ca.crt --api-server=$api_server
say "Installed kube-proxy"

pushd $STAGING_FOLDER

say "Installing CNI plug-ins"
sudo mkdir -p /opt/cni/bin
sudo wget https://github.com/containernetworking/plugins/releases/download/v0.8.3/cni-plugins-linux-amd64-v0.8.3.tgz
sudo tar -xvf cni-plugins-linux-amd64-v0.8.3.tgz -C /opt/cni/bin/
say "Installed CNI plug-ins"

if [  $install_network_addon = true ]
then	
say "Installing network add-on"
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
say "Installed network add-on"
fi

popd

say "Removing staging folder"
sudo rm -r $STAGING_FOLDER

say "Installed all worker node components"



