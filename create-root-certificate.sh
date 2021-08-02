#!/bin/bash
K8s_PKI_FOLDER="/etc/kubernetes/pki"

sudo mkdir $K8s_PKI_FOLDER -p
pushd $K8s_PKI_FOLDER

sudo openssl genrsa -out ca.key 2048
sudo openssl req -new -key ca.key -subj="/CN=KUBERNETES" -out ca.csr
sudo openssl x509 -req -in ca.csr -signkey ca.key -CAcreateserial -out ca.crt  -days 1000
sudo openssl x509 -in ca.crt -noout -text
sudo rm ca.csr

popd
