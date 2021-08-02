#!/bin/bash
K8S_VERSION="v1.21.3"
STAGING_FOLDER="/tmp/create-admin-config"


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

function create_kubeconfig(){

	pushd  $STAGING_FOLDER

	say "Creating certificates"

	openssl genrsa -out admin.key 2048
	openssl req -new -key admin.key -subj="/CN=admin/O=system:masters" -out admin.csr
	openssl x509 -req -in admin.csr -CA $ca_crt -CAkey $ca_key -CAcreateserial -out admin.crt -days 1000 
	openssl x509 -in admin.crt -noout -text

	say "Certificate created.. now creating kubeconfig"

	kubectl config set-cluster shaijus-cluster --embed-certs --certificate-authority $ca_crt --server=https://$api_server:6443 --kubeconfig config
	kubectl config set-credentials admin --embed-certs=true --client-certificate admin.crt --client-key admin.key --kubeconfig config
	kubectl config set-context shaijus-cluster-admin --user=admin --cluster=shaijus-cluster --kubeconfig config
	kubectl config use-context shaijus-cluster-admin --kubeconfig config

	mkdir ~/.kube -p

	sudo cp config ~/.kube

	sudo chown $(id -u):$(id -g) ~/.kube/config

	say "Auth files copied to corresponding folders"

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
			say "Creates a kube-config file to connect to the given cluster"
			say "Usage:"
			say "\t $scipt_name --ca-key <PATH TO CA KEY FILE> --ca-crt <PATH TO CA CRT FILE> --api-server <IP Address of api-server>"
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

say "Creating kube config."

create_kubeconfig

say "Kubeconfig copied to ~/.kube. Deleting the staging folder $STAGING_FOLDER"

sudo rm -r $STAGING_FOLDER

say "Execution complete"

