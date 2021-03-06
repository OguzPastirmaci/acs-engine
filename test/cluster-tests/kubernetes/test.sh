#!/bin/bash

# exit on errors
set -e
# exit on unbound variables
set -u
# verbose logging
set -x

EXPECTED_NODE_COUNT="${EXPECTED_NODE_COUNT:-4}"
EXPECTED_DNS="${EXPECTED_DNS:-2}"
EXPECTED_DASHBOARD="${EXPECTED_DASHBOARD:-1}"

namespace="namespace-${RANDOM}"
echo "Running test in namespace: ${namespace}"
trap teardown EXIT

function teardown {
  kubectl get all --all-namespaces
  kubectl delete namespaces ${namespace}
}

# TODO: cleanup the loops more
# TODO: the wc|awk business can just be kubectl with an output format and wc -l

###### Check node count
wait=5
count=12
while (( $count > 0 )); do
  node_count=$(kubectl get nodes --no-headers | wc | awk '{print $1}')
  if (( ${node_count} == ${EXPECTED_NODE_COUNT} )); then break; fi
  sleep 5; count=$((count-1))
done
if (( $node_count != ${EXPECTED_NODE_COUNT} )); then
  echo "gave up waiting for apiserver / node counts"; exit -1
fi

###### Wait for no more container creating
wait=5
count=12
while (( $count > 0 )); do
  creating_count=$(kubectl get nodes --no-headers | grep 'ContainerCreating' | wc | awk '{print $1}')
  if (( ${creating_count} == 0 )); then break; fi
  sleep 5; count=$((count-1))
done
if (( ${creating_count} != 0 )); then
  echo "gave up waiting for creation to finish"; exit -1
fi


###### Check for Kube-DNS
wait=5
count=12
while (( $count > 0 )); do
  running=$(kubectl get pods --namespace=kube-system | grep kube-dns | grep Running | wc | awk '{print $1}')
  if (( ${running} == ${EXPECTED_DNS} )); then break; fi
  sleep 5; count=$((count-1))
done
if (( ${running} != ${EXPECTED_DNS} )); then
  echo "gave up waiting for kube-dns"; exit -1
fi

###### Check for Kube-Dashboard
wait=5
count=12
while (( $count > 0 )); do
  running=$(kubectl get pods --namespace=kube-system | grep kubernetes-dashboard | grep Running | wc | awk '{print $1}')
  if (( ${running} == ${EXPECTED_DASHBOARD} )); then break; fi
  sleep 5; count=$((count-1))
done
if (( ${running} != ${EXPECTED_DASHBOARD} )); then
  echo "gave up waiting for kubernetes-dashboard"; exit -1
fi

###### Check for Kube-Proxys
wait=5
count=12
while (( $count > 0 )); do
  running=$(kubectl get pods --namespace=kube-system | grep kube-proxy | grep Running | wc | awk '{print $1}')
  if (( ${running} == ${EXPECTED_NODE_COUNT} )); then break; fi
  sleep 5; count=$((count-1))
done
if (( ${running} != ${EXPECTED_NODE_COUNT} )); then
  echo "gave up waiting for kube-proxies"; exit -1
fi

###### Testing an nginx deployment
echo "Testing deployments"
kubectl create namespace ${namespace}

kubectl run --image=nginx nginx --namespace=${namespace}
wait=5
count=12
while (( $count > 0 )); do
  running=$(kubectl get pods --namespace=${namespace} | grep nginx | grep Running | wc | awk '{print $1}')
  if (( ${running} == 1 )); then break; fi
  sleep 5; count=$((count-1))
done
if (( ${running} != 1 )); then
  echo "gave up waiting for deployment"
  kubectl get all --namespace=${namespace}
  exit -1
fi

kubectl expose deployments/nginx --type=LoadBalancer --namespace=${namespace} --port=80

wait=5
count=60
external_ip=""
while true; do
	external_ip=$(kubectl get svc --namespace ${namespace} nginx --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}")
	[[ ! -z "${external_ip}" ]] && break
	sleep 10
done
if [[ -z "${external_ip}" ]]; then
  echo "gave up waiting for loadbalancer to get an ingress ip"
  exit -1
fi

count=5
success="n"
while (( $count > 0 )); do
	curl -f "http://${external_ip}" | grep 'Welcome to nginx!'
	if [[ $? == 0 ]]; then
		success="y"
		break;
	fi
done
if [[ "${success}" != "y" ]]; then
  echo "failed to get expected response from nginx through the loadbalancer"
  exit -1
fi


