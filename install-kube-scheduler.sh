#!/bin/bash
HOST_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
HOST_NAME=$(hostname)
K8S_VERSION="v1.21.3"
STAGING_FOLDER="/tmp/kube-scheduler-install"
KUBERNETES_PKI_FOLDER="/etc/kubernetes/pki"
KUBE_SCHEDULER_CONFIG_FOLDER="/var/lib/kube-scheduler"

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
		"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kube-scheduler" 
	chmod +x kube-scheduler
	sudo mv  kube-scheduler /usr/local/bin
	say "k8s binaries copied to bin folder"
}

function create_auth_files(){
	pushd  $STAGING_FOLDER

	say "Creating certificates"

	sudo openssl genrsa -out kube-scheduler.key 2048
	sudo openssl req -new -key kube-scheduler.key -subj="/CN=system:kube-scheduler" -out kube-scheduler.csr
	sudo openssl x509 -req -in kube-scheduler.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out kube-scheduler.crt -days 1000 
	sudo openssl x509 -in kube-scheduler.crt -noout -text

	say "Certificate created.. now creating kubeconfig"

	sudo kubectl config set-cluster shaijus-cluster --embed-certs --certificate-authority $ca_crt --server=https://$api_server:6443 --kubeconfig kubeconfig
	sudo kubectl config set-credentials kube-scheduler --embed-certs=true --client-certificate kube-scheduler.crt --client-key kube-scheduler.key --kubeconfig kubeconfig
	sudo kubectl config set-context shaijus-cluster-kube-scheduler --user=kube-scheduler --cluster=shaijus-cluster --kubeconfig kubeconfig
	sudo kubectl config use-context shaijus-cluster-kube-scheduler --kubeconfig kubeconfig
	
	say "kubeconfig created.. now creating kube-scheduler config"

	sudo mkdir $KUBERNETES_PKI_FOLDER/kube-scheduler -p
	sudo mkdir $KUBE_SCHEDULER_CONFIG_FOLDER -p

	sudo cp kube-scheduler.key kube-scheduler.crt  $KUBERNETES_PKI_FOLDER/kube-scheduler
	sudo cp kubeconfig $KUBE_SCHEDULER_CONFIG_FOLDER

	say "Auth files copied to corresponding folders"

	popd
}

function create_service_unit(){

	pushd $STAGING_FOLDER

	cat > kube-scheduler.service <<-EOF
	[Unit]
	Description=Kubernetes Scheduler
	Documentation=https://github.com/kubernetes/kubernetes

	[Service]
	ExecStart=kube-scheduler \
	--authentication-kubeconfig=$KUBE_SCHEDULER_CONFIG_FOLDER/kubeconfig \
	--authorization-kubeconfig=$KUBE_SCHEDULER_CONFIG_FOLDER/kubeconfig \
	--bind-address=127.0.0.1 \
	--kubeconfig=$KUBE_SCHEDULER_CONFIG_FOLDER/kubeconfig \
	--leader-elect=true
	Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=multi-user.target
	EOF

	sudo cp kube-scheduler.service /etc/systemd/system
	sudo systemctl daemon-reload
	sudo systemctl enable kube-scheduler
	sudo systemctl start kube-scheduler

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
			say "Installs Kubernetes Kube-Scheduler"
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

sudo rm -r $STAGING_FOLDER 2>/dev/null
mkdir $STAGING_FOLDER -p

say "Creating auth files."

create_auth_files

say "Creating kuebe-scheduler service"

create_service_unit

say "Deleting the staging folder $STAGING_FOLDER"

sudo rm -r $STAGING_FOLDER

say "Execution complete"

