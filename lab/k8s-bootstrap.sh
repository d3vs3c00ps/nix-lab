#!/usr/bin/env bash
# Brings up the lab Kubernetes cluster after `lab.sh up k8s-01 k8s-02 k8s-03`:
# join the workers, install Cilium and CoreDNS with Helm, check the pod network.
# Safe to run again. Versions match RUNBOOK.md section 10.
set -euo pipefail
lab() { "$(dirname "$0")/lab.sh" "$@"; }
# Root on k8s-01 (KUBECONFIG is set there). set -e: a failed step must fail the script.
k() { lab ssh k8s-01 "set -e; $*"; }

for h in k8s-02 k8s-03; do
  if k "kubectl get node $h" >/dev/null 2>&1; then echo "$h already joined"; continue; fi
  echo "== join $h"
  # The token goes from the master to the worker and is never printed.
  k 'cat /var/lib/kubernetes/secrets/apitoken.secret' | lab ssh "$h" nixos-kubernetes-node-join
done

echo "== cilium and coredns"
k 'helm repo add cilium https://helm.cilium.io >/dev/null
   helm repo add coredns https://coredns.github.io/helm >/dev/null
   helm upgrade --install cilium cilium/cilium -n kube-system --version 1.20.2 -f /etc/cilium/values.yaml
   cilium status --wait --wait-duration 10m
   helm upgrade --install coredns coredns/coredns -n kube-system --version 1.48.2 -f /etc/coredns/values.yaml
   kubectl -n kube-system rollout status deploy/coredns --timeout=5m
   kubectl wait --for=condition=Ready node --all --timeout=5m'

echo "== pod network test: a pod on k8s-02 resolves a cluster name"
k 'kubectl delete pod nettest --ignore-not-found >/dev/null
   kubectl run nettest --image=busybox:1.37 --restart=Never \
     --overrides="{\"spec\":{\"nodeName\":\"k8s-02\"}}" -- \
     sh -c "nslookup kubernetes.default.svc.cluster.local"
   kubectl wait --for=jsonpath={.status.phase}=Succeeded pod/nettest --timeout=3m
   kubectl logs nettest; kubectl delete pod nettest >/dev/null
   kubectl get nodes -o wide'
echo "== mac-admin ServiceAccount (cluster-admin) for kubectl on the Mac: lab.sh kubeconfig"
k 'kubectl apply -f -' <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata: { name: mac-admin, namespace: kube-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: mac-admin }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [ { kind: ServiceAccount, name: mac-admin, namespace: kube-system } ]
---
apiVersion: v1
kind: Secret
metadata:
  name: mac-admin-token
  namespace: kube-system
  annotations: { kubernetes.io/service-account.name: mac-admin }
type: kubernetes.io/service-account-token
YAML
echo "cluster OK"
