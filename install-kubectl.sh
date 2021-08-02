#!/bin/bash
exec 3>&1

function say(){
	printf "%b\n" "Info:$1" >&3
}	

say "Downloading kubectl"
wget -q --show-progress --https-only --timestamping \
	"https://storage.googleapis.com/kubernetes-release/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin
say "Kubectl installed"


