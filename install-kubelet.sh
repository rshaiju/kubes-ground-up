#!/bin/bash
HOST_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
HOST_NAME=$(hostname)
K8S_VERSION="v1.21.3"
STAGING_FOLDER="/tmp/kubelet-install"
KUBERNETES_PKI_FOLDER="/etc/kubernetes/pki"
KUBELET_CONFIG_FOLDER="/var/lib/kubelet"

ca_key="";
ca_crt="";

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
		"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubelet" \
		"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
	chmod +x kubectl kubelet
	sudo mv kubectl kubelet /usr/local/bin
	say "k8s binaries copied to bin folder"
}

function create_auth_files(){
	pushd  $STAGING_FOLDER

	say "creating certificates"
	sudo cat > openssl-${HOST_NAME}.cnf <<-EOF
	[req]
	req_extensions = v3_req
	distinguished_name = req_distinguished_name
	[req_distinguished_name]
	[ v3_req ]
	basicConstraints = CA:FALSE
	keyUsage = nonRepudiation, digitalSignature, keyEncipherment
	subjectAltName = @alt_names
	[alt_names]
	DNS.1=${HOST_NAME}
	IP.1=${HOST_IP}
	IP.2=127.0.0.1
	EOF

	openssl genrsa -out ${HOST_NAME}.key 2048
	openssl req -new -key ${HOST_NAME}.key -subj="/CN=system:node:${HOST_NAME}/O=system:nodes" -out ${HOST_NAME}.csr -config openssl-${HOST_NAME}.cnf
	openssl x509 -req -in ${HOST_NAME}.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out ${HOST_NAME}.crt -days 1000 -extensions v3_req -extfile openssl-${HOST_NAME}.cnf
	openssl x509 -in ${HOST_NAME}.crt -noout -text

	say "Certificates created.. now creating kubeconfig"

	kubectl config set-cluster shaijus-cluster --embed-certs --certificate-authority $ca_crt --server=https://10.0.0.4:6443 --kubeconfig kubeconfig
	kubectl config set-credentials ${HOST_NAME} --embed-certs=true --client-certificate ${HOST_NAME}.crt --client-key ${HOST_NAME}.key --kubeconfig kubeconfig
	kubectl config set-context shaijus-cluster-${HOST_NAME} --user=${HOST_NAME} --cluster=shaijus-cluster --kubeconfig kubeconfig
	kubectl config use-context shaijus-cluster-${HOST_NAME} --kubeconfig kubeconfig
	
	say "kubeconfig created.. now kubelet config"

	sudo cat > ${HOST_NAME}-config.yaml <<-EOF
	apiVersion: kubelet.config.k8s.io/v1beta1
	kind: KubeletConfiguration
	authentication:
	  anonymous:
	      enabled: false
	  webhook:
	    enabled: true
	  x509:
	    clientCAFile: $KUBERNETES_PKI_FOLDER/ca.crt
	authorization:
	  mode: Webhook
	clusterDNS:
	- 10.96.0.10
	clusterDomain: cluster.local
	resolvConf: /run/systemd/resolve/resolv.conf
	runtimeRequestTimeout: "15m"
	EOF

	say "kubelet config created..now copying the prepared files"

	sudo mkdir $KUBERNETES_PKI_FOLDER/kubelet -p
	sudo mkdir $KUBELET_CONFIG_FOLDER -p


	sudo cp $ca_crt  $ca_key $KUBERNETES_PKI_FOLDER
	sudo cp ${HOST_NAME}.key ${HOST_NAME}.crt  $KUBERNETES_PKI_FOLDER/kubelet
	sudo cp kubeconfig ${HOST_NAME}-config.yaml $KUBELET_CONFIG_FOLDER

	say "auth files copied to corresponding folders"

	popd
}

function create_service_unit(){

	pushd $STAGING_FOLDER

	cat > kubelet.service <<-EOF
	[Unit]
	Description=Kubernetes Kubelet
	Documentation=https://github.com/kubernetes/kubernetes
	After=docker.service                                                                                                                                                                                               Requires=docker.service                                                                                                                                                                                            
	[Service]
	ExecStart=kubelet \
	--config=$KUBELET_CONFIG_FOLDER/${HOST_NAME}-config.yaml\
	--kubeconfig=$KUBELET_CONFIG_FOLDER/kubeconfig  \
	--image-pull-progress-deadline=2m  \
	--tls-cert-file=$KUBERNETES_PKI_FOLDER/kubelet/${HOST_NAME}.crt  \
	--tls-private-key-file=$KUBERNETES_PKI_FOLDER/kubelet/${HOST_NAME}.key \
	--network-plugin=cni \
	--register-node=true \
	--v=2                                                                                                                                                                                                              Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=multi-user.target
	EOF

	sudo cp kubelet.service /etc/systemd/system
	sudo systemctl daemon-reload
	sudo systemctl enable kubelet
	sudo systemctl start kubelet

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
			say "Installs Kubernetes Kubelet"
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

sudo rm - $STAGING_FOLDER
mkdir $STAGING_FOLDER -p

say "Creating auth files."

create_auth_files

say "Creating kuebelet service"

create_service_unit

say "Deleting the staging folder $STAGING_FOLDER"

sudo rm -r $STAGING_FOLDER

say "Execution complete"
