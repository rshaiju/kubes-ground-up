#!/bin/bash
HOST_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
HOST_NAME=$(hostname)
K8S_VERSION="v1.21.3"
STAGING_FOLDER="/tmp/kube-apiserver-install"
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
		"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kube-apiserver" \
		"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
	chmod +x kubectl kube-apiserver
	sudo mv kubectl kube-apiserver /usr/local/bin
	say "k8s binaries copied to bin folder"
}

function create_auth_files(){
	pushd  $STAGING_FOLDER

	say "Creating certificates"
	sudo cat > openssl.cnf <<-EOF
	[req]
	req_extensions = v3_req
	distinguished_name = req_distinguished_name
	[req_distinguished_name]
	[ v3_req ]
	basicConstraints = CA:FALSE
	keyUsage = nonRepudiation, digitalSignature, keyEncipherment
	subjectAltName = @alt_names
	[alt_names]
	DNS.1 = kubernetes
	DNS.2 = kubernetes.default
	DNS.3 = kubernetes.default.svc
	DNS.4 = kubernetes.default.svc.cluster.local
	IP.1 = 10.96.0.1
	IP.2=${HOST_IP}
	IP.3=127.0.0.1
	EOF

	sudo openssl genrsa -out kube-apiserver.key 2048
	sudo openssl req -new -key kube-apiserver.key -subj="/CN=kube-apiserver" -out kube-apiserver.csr -config openssl.cnf
	sudo openssl x509 -req -in kube-apiserver.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out kube-apiserver.crt -extensions v3_req -extfile openssl.cnf -days 1000
	sudo openssl x509 -in kube-apiserver.crt -noout -text

	sudo openssl genrsa -out kubelet-client.key 2048
	sudo openssl req -new -key kubelet-client.key -subj="/CN=kubelet-client/O=system:masters" -out kubelet-client.csr
	sudo openssl x509 -req -in kubelet-client.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out kubelet-client.crt -days 1000
	sudo openssl x509 -in kubelet-client.crt -noout -text

	sudo openssl genrsa -out front-proxy-client.key 2048
	sudo openssl req -new -key front-proxy-client.key -subj="/CN=front-proxy-client" -out front-proxy-client.csr
	sudo openssl x509 -req -in front-proxy-client.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out front-proxy-client.crt -days 1000
	sudo openssl x509 -in front-proxy-client.crt -noout -text

	sudo openssl genrsa -out sa.key 2048
	sudo openssl rsa -in sa.key -pubout -out sa.pub

	sudo mkdir $KUBERNETES_PKI_FOLDER/kube-apiserver -p

	sudo cp kube-apiserver.key kube-apiserver.crt kubelet-client.key kubelet-client.crt front-proxy-client.key front-proxy-client.crt $KUBERNETES_PKI_FOLDER/kube-apiserver
	sudo cp $ca_key $ca_crt sa.key sa.pub $KUBERNETES_PKI_FOLDER 

	say "Auth files copied to corresponding folders"

	popd
}

function create_service_unit(){

	pushd $STAGING_FOLDER
	
	sudo cat > kube-apiserver.service <<-EOF
	[Unit]
	Description=Kubernetes API Server
	Documentation=https://github.com/kubernetes/kubernetes

	[Service]
	ExecStart=kube-apiserver \
	--advertise-address=${HOST_IP} \
	--allow-privileged=true \
	--authorization-mode=Node,RBAC \
	--client-ca-file=$KUBERNETES_PKI_FOLDER/ca.crt \
	--enable-admission-plugins=NodeRestriction \
	--enable-bootstrap-token-auth=true \
	--etcd-cafile=$KUBERNETES_PKI_FOLDER/ca.crt \
	--etcd-certfile=$KUBERNETES_PKI_FOLDER/etcd/etcd-client.crt \
	--etcd-keyfile=$KUBERNETES_PKI_FOLDER/etcd/etcd-client.key \
	--etcd-servers=https://127.0.0.1:2379 \
	--insecure-port=0 \
	--kubelet-client-certificate=$KUBERNETES_PKI_FOLDER/kube-apiserver/kubelet-client.crt \
	--kubelet-client-key=$KUBERNETES_PKI_FOLDER/kube-apiserver/kubelet-client.key \
	--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname \
	--proxy-client-cert-file=$KUBERNETES_PKI_FOLDER/kube-apiserver/front-proxy-client.crt \
	--proxy-client-key-file=$KUBERNETES_PKI_FOLDER/kube-apiserver/front-proxy-client.key \
	--requestheader-allowed-names=front-proxy-client \
	--requestheader-client-ca-file=$KUBERNETES_PKI_FOLDER/ca.crt \
	--requestheader-extra-headers-prefix=X-Remote-Extra- \
	--requestheader-group-headers=X-Remote-Group \
	--requestheader-username-headers=X-Remote-User \
	--secure-port=6443 \
	--service-account-issuer=https://kubernetes.default.svc.cluster.local \
	--service-account-key-file=$KUBERNETES_PKI_FOLDER/sa.pub \
	--service-account-signing-key-file=$KUBERNETES_PKI_FOLDER/sa.key \
	--service-cluster-ip-range=10.96.0.0/12 \
	--tls-cert-file=$KUBERNETES_PKI_FOLDER/kube-apiserver/kube-apiserver.crt \
	--tls-private-key-file=$KUBERNETES_PKI_FOLDER/kube-apiserver/kube-apiserver.key
	Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=multi-user.target
	EOF

	sudo cp kube-apiserver.service /etc/systemd/system
	sudo systemctl daemon-reload
	sudo systemctl enable kube-apiserver
	sudo systemctl start kube-apiserver

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
			say "Installs kube-apiserver server"
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

sudo rm -r $STAGING_FOLDER
mkdir $STAGING_FOLDER -p

download_kube-apiserver_binaries

say "Creating auth files."

create_auth_files

say "Creating kube-apiserver service"

create_service_unit

say "Deleting the staging folder $STAGING_FOLDER"

sudo rm -r $STAGING_FOLDER

curl  https://127.0.0.1:6443/version -k

say "Execution complete"



