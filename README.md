# kubes-ground-up

This project helps set up a signle master k8s environment in freshly installed ubuntu machines. The only preqrequisite is that the machines should be able to reach each other.

Following are the steps to perform

**In control plane**
1. Clone the repository
1. Execute the script - install-controlplane.sh
1. Copy the files ca.crt and ca.key from /etc/kubernetes/pki to each worker node

**Verification**
- Run *kubectl get cs*. This will show the health of etcd, kube-controller-manager and kube-scheduler

**In worker node**
1. Clone the repository
1. Execute the script install-docker.sh
1. Execute the script install-kube-worker.sh providing the following arguments
   - --ca-key={fully qualified path to the ca.key file copied from the controlplane node}
   - --ca-crt={fully qualified path to the ca.crt file copied from the controlplane node}
   - --api-server={ip address of the controlplane node}
   - --install-network-addon (Only in the first worker node. This installs the k8s network plug-in for the cluster)
   
**Verification**
- Run *kubectl get nodes*. On a succesful installation, you should see the worker node in Ready state
