#!/bin/bash
HOST_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
HOST_NAME=$(hostname)
ETCD_VER="v3.5.0"
STAGING_FOLDER="/tmp/etcd-install"
ETCD_PKI_FOLDER="/etc/kubernetes/pki/etcd"
K8s_PKI_FOLDER="/etc/kubernetes/pki"

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

function download_etcd_binaries()
{
	pushd  $STAGING_FOLDER
	say "Downloading etcd binaries"
	curl -L https://storage.googleapis.com/etcd/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o $STAGING_FOLDER/etcd-${ETCD_VER}-linux-amd64.tar.gz
	tar xzvf $STAGING_FOLDER/etcd-${ETCD_VER}-linux-amd64.tar.gz  -C $STAGING_FOLDER/
	sudo mv $STAGING_FOLDER/etcd-${ETCD_VER}-linux-amd64/etcd $STAGING_FOLDER/etcd-${ETCD_VER}-linux-amd64/etcdctl $STAGING_FOLDER/etcd-${ETCD_VER}-linux-amd64/etcdutl /usr/local/bin
	say "k8s binaries copied to bin folder"
	etcd --version
	etcdctl version
	etcdutl version
	sudo rm -r $STAGING_FOLDER/* 
	popd
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
	IP.1=${HOST_IP}
	IP.2=127.0.0.1
	EOF

	openssl genrsa -out etcd.key 2048
	openssl req -new -key etcd.key -subj="/CN=ETCD" -out etcd.csr -config openssl.cnf
	openssl x509 -req -in etcd.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out etcd.crt -days 1000 -extensions=v3_req -extfile=openssl.cnf
	openssl x509 -in etcd.crt -noout -text

	say "Server certificate created.. now creating the client one"

	sudo openssl genrsa -out etcd-client.key 2048
	sudo openssl req -new -key etcd-client.key -subj="/CN=ETCD-CLIENT" -out etcd-client.csr
	sudo openssl x509 -req -in etcd-client.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out etcd-client.crt -days 1000
	sudo openssl x509 -in etcd-client.crt -noout -text
	
	say "Client certificate created.. now copying the certificates to pki folders"

 	sudo mkdir $ETCD_PKI_FOLDER -p

	sudo cp etcd.key etcd.crt etcd-client.key etcd-client.crt $ETCD_PKI_FOLDER

	say "Auth files copied to corresponding folders"

	popd
}

function create_service_unit(){

	pushd $STAGING_FOLDER
	
	sudo cat > etcd.service <<-EOF
	[Unit]
	Description=etcd
	Documentation=https://github.com/etcd-io/etcd

	[Service]
	ExecStart=etcd \
	--advertise-client-urls=https://${HOST_IP}:2379 \
	--cert-file=$ETCD_PKI_FOLDER/etcd.crt \
	--client-cert-auth=true \
	--data-dir=/var/lib/etcd
	--initial-advertise-peer-urls=https://${HOST_IP}:2380 \
	--initial-cluster=controlplane=https://${HOST_IP}:2380 \
	--key-file=$ETCD_PKI_FOLDER/etcd.key \
	--listen-client-urls=https://127.0.0.1:2379,https://${HOST_IP}:2379 \
	--listen-metrics-urls=http://127.0.0.1:2381 \
	--listen-peer-urls=https://${HOST_IP}:2380 \
	--name=$HOST_NAME \
	--peer-cert-file=$ETCD_PKI_FOLDER/etcd.crt \
	--peer-client-cert-auth=true \
	--peer-key-file=$ETCD_PKI_FOLDER/etcd.key \
	--peer-trusted-ca-file=$K8s_PKI_FOLDER/ca.crt \
	--snapshot-count=10000 \
	--trusted-ca-file=$K8s_PKI_FOLDER/ca.crt
	Restart=on-failure
	RestartSec=5

	[Install]
	WantedBy=multi-user.target
	EOF

	sudo cp etcd.service /etc/systemd/system
	sudo systemctl daemon-reload
	sudo systemctl enable etcd
	sudo systemctl start etcd

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
			say "Installs etcd server"
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

download_etcd_binaries

say "Creating auth files."

create_auth_files

say "Creating kuebe-scheduler service"

create_service_unit

say "Deleting the staging folder $STAGING_FOLDER"

sudo rm -r $STAGING_FOLDER

sudo ETCDCTL_API=3 etcdctl put foo bar --endpoints=https://127.0.0.1:2379 --cacert=$K8s_PKI_FOLDER/ca.crt --cert=$ETCD_PKI_FOLDER/etcd-client.crt --key=$ETCD_PKI_FOLDER/etcd-client.key

say "Execution complete"


