#!/bin/bash
HOST_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
HOST_NAME=$(hostname)
K8S_VERSION="v1.21.3"
STAGING_FOLDER="/tmp/kube-controller-manager-install"
KUBERNETES_PKI_FOLDER="/etc/kubernetes/pki"
KUBE_CONTROLLER_MANAGER_CONFIG_FOLDER="/var/lib/kube-controller-manager"

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

function download_k8s_binaries()
{
	say "Downloading k8s binaries"
	wget -q --show-progress --https-only --timestamping \
		"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kube-controller-manager" 
	chmod +x kube-controller-manager
	sudo mv kube-controller-manager /usr/local/bin
	say "k8s binaries copied to bin folder"
}

function create_auth_files(){
	pushd  $STAGING_FOLDER

	say "Creating certificates"

	openssl genrsa -out kube-controller-manager.key 2048
	openssl req -new -key kube-controller-manager.key -subj="/CN=system:kube-controller-manager" -out kube-controller-manager.csr
	openssl x509 -req -in kube-controller-manager.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out kube-controller-manager.crt -days 1000 
	openssl x509 -in kube-controller-manager.crt -noout -text

	say "Certificate created.. now creating kubeconfig"

	kubectl config set-cluster shaijus-cluster --embed-certs --certificate-authority $ca_crt --server=https://$api_server:6443 --kubeconfig kubeconfig
	kubectl config set-credentials kube-controller-manager --embed-certs=true --client-certificate kube-controller-manager.crt --client-key kube-controller-manager.key --kubeconfig kubeconfig
	kubectl config set-context shaijus-cluster-kube-controller-manager --user=kube-controller-manager --cluster=shaijus-cluster --kubeconfig kubeconfig
	kubectl config use-context shaijus-cluster-kube-controller-manager --kubeconfig kubeconfig
	
	say "kubeconfig created.. now copying the files"

	sudo mkdir $KUBERNETES_PKI_FOLDER/kube-controller-manager -p
	sudo mkdir $KUBE_CONTROLLER_MANAGER_CONFIG_FOLDER -p

	sudo cp kube-controller-manager.key kube-controller-manager.crt  $KUBERNETES_PKI_FOLDER/kube-controller-manager
	sudo cp kubeconfig $KUBE_CONTROLLER_MANAGER_CONFIG_FOLDER

	say "Auth files copied to corresponding folders"

	popd
}

function create_service_unit(){

	pushd $STAGING_FOLDER

	cat > kube-controller-manager.service <<-EOF
	[Unit]
	Description=Kubernetes Controller Manager
	Documentation=https://github.com/kubernetes/kubernetes

	[Service]
	ExecStart=kube-controller-manager \
	--authentication-kubeconfig=$KUBE_CONTROLLER_MANAGER_CONFIG_FOLDER/kubeconfig \
	--authorization-kubeconfig=$KUBE_CONTROLLER_MANAGER_CONFIG_FOLDER/kubeconfig \
	--bind-address=127.0.0.1 \
	--client-ca-file=$KUBERNETES_PKI_FOLDER/ca.crt \
	--cluster-name=kubernetes \
	--cluster-signing-cert-file=$KUBERNETES_PKI_FOLDER/ca.crt \
	--cluster-signing-key-file=$KUBERNETES_PKI_FOLDER/ca.key \
	--controllers=*,bootstrapsigner,tokencleaner \
	--kubeconfig=$KUBE_CONTROLLER_MANAGER_CONFIG_FOLDER/kubeconfig \
	--leader-elect=true \
	--requestheader-client-ca-file=$KUBERNETES_PKI_FOLDER/ca.crt \
	--root-ca-file=$KUBERNETES_PKI_FOLDER/ca.crt \
	--service-account-private-key-file=$KUBERNETES_PKI_FOLDER/sa.key \
	--use-service-account-credentials=true
	Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=multi-user.target
	EOF

	sudo cp kube-controller-manager.service /etc/systemd/system
	sudo systemctl daemon-reload
	sudo systemctl enable kube-controller-manager
	sudo systemctl start kube-controller-manager

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
		--api-server=*)
			api_server="${1#*=}"
			shift 1;
			;;
		--help)
			say "Installs Kubernetes Kube-Controller-Manager"
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

say "Creating kube-controller-manager service"

create_service_unit

say "Deleting the staging folder $STAGING_FOLDER"

sudo rm -r $STAGING_FOLDER

say "Execution complete"


