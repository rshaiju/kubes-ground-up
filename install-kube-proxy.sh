#!/bin/bash
HOST_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
HOST_NAME=$(hostname)
K8S_VERSION="v1.21.3"
STAGING_FOLDER="/tmp/kube-proxy-install"
KUBERNETES_PKI_FOLDER="/etc/kubernetes/pki"
KUBE_PROXY_CONFIG_FOLDER="/var/lib/kube-proxy"

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
}	

function download_k8s_binaries()
{
	say "Downloading k8s binaries"
	wget -q --show-progress --https-only --timestamping \
		"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kube-proxy" \
		"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
	chmod +x kubectl kube-proxy
	sudo mv kubectl kube-proxy /usr/local/bin
	say "k8s binaries copied to bin folder"
}

function create_auth_files(){
	pushd  $STAGING_FOLDER

	say "Creating certificates"

	openssl genrsa -out kube-proxy.key 2048
	openssl req -new -key kube-proxy.key -subj="/CN=system:kube-proxy" -out kube-proxy.csr
	openssl x509 -req -in kube-proxy.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out kube-proxy.crt -days 1000 
	openssl x509 -in kube-proxy.crt -noout -text

	say "Certificate created.. now creating kubeconfig"

	kubectl config set-cluster shaijus-cluster --embed-certs --certificate-authority $ca_crt --server=https://10.0.0.4:6443 --kubeconfig kubeconfig
	kubectl config set-credentials kube-proxy --embed-certs=true --client-certificate kube-proxy.crt --client-key kube-proxy.key --kubeconfig kubeconfig
	kubectl config set-context shaijus-cluster-kube-proxy --user=kube-proxy --cluster=shaijus-cluster --kubeconfig kubeconfig
	kubectl config use-context shaijus-cluster-kube-proxy --kubeconfig kubeconfig
	
	say "kubeconfig created.. now creating kube-proxy config"

	sudo cat > config.yaml <<-EOF
	apiVersion: kubeproxy.config.k8s.io/v1alpha1
	kind: KubeProxyConfiguration
	clientConnection:
	  kubeconfig: $KUBE_PROXY_CONFIG_FOLDER/kubeconfig 
	clusterCIDR: "10.96.0.0/12"
	mode: ""
	EOF

	say "kube-proxy config created..now copying the prepared files"

	sudo mkdir $KUBERNETES_PKI_FOLDER/kube-proxy -p
	sudo mkdir $KUBE_PROXY_CONFIG_FOLDER -p


	sudo cp $ca_crt  $ca_key $KUBERNETES_PKI_FOLDER
	sudo cp kube-proxy.key kube-proxy.crt  $KUBERNETES_PKI_FOLDER/kube-proxy
	sudo cp kubeconfig config.yaml $KUBE_PROXY_CONFIG_FOLDER

	say "Auth files copied to corresponding folders"

	popd
}

function create_service_unit(){

	pushd $STAGING_FOLDER

	cat > kube-proxy.service <<-EOF
	[Unit]
	Description=Kubernetes Kube Proxy
	Documentation=https://github.com/kubernetes/kubernetes

	[Service]
	ExecStart=kube-proxy --config=${KUBE_PROXY_CONFIG_FOLDER}/config.yaml
	Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=multi-user.target
	EOF

	sudo cp kube-proxy.service /etc/systemd/system
	sudo systemctl daemon-reload
	sudo systemctl enable kube-proxy
	sudo systemctl start kube-proxy

	popd
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
		--help)
			say "Installs Kubernetes Kube-Proxy"
			say "Usage:"
			say "\t $scipt_name --ca-key <PATH TO CA KEY FILE> --ca-crt <PATH TO CA CRT FILE>"
			exit 0
			;;
		*)
			say_err "Uknown option $1"
			exit 1;
			;;
	esac
done

validate_args

download_k8s_binaries

sudo rm -r $STAGING_FOLDER
mkdir $STAGING_FOLDER -p

say "Creating auth files."

create_auth_files

say "Creating kuebelet service"

create_service_unit

say "Deleting the staging folder $STAGING_FOLDER"

sudo rm -r $STAGING_FOLDER

say "Execution complete"

