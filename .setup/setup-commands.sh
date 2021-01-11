# This script requires the JQ package
#
# After helm deploy
# Wait for vault pod

#Should run in the pod shell - kubectl -n vault exec -it tooling-vault-0 -- /bin/sh

kubectl -n vault exec -it tooling-vault-0 -- /bin/sh

kubectl -n vault exec -it tooling-vault-0 -- vault operator init -format=json > cluster-keys.json

kubectl -n vault exec -it tooling-vault-0 -- vault operator unseal $(cat cluster-keys.json | jq -r ".unseal_keys_b64[0]")
kubectl -n vault exec -it tooling-vault-0 -- vault operator unseal $(cat cluster-keys.json | jq -r ".unseal_keys_b64[1]")
kubectl -n vault exec -it tooling-vault-0 -- vault operator unseal $(cat cluster-keys.json | jq -r ".unseal_keys_b64[2]")

vault login -no-print=true token=$(cat cluster-keys.json | jq -r ".root_token")

vault secrets enable -path=k8s kv-v2

vault kv put k8s/secrets/github-ssh github="<secret>" #Replace with github key.

vault auth enable kubernetes

vault write auth/kubernetes/config token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

vault policy write k8s-secrets - <<EOF
path "k8s/*" {
	capabilities = ["read"]
}
EOF

#This namespace might change to whatever is going to use the git ssh. That being Argo and ArgoCD as of now.
#The service account name should be that same as the one in the setup.yaml
vault write auth/kubernetes/role/k8s-secrets bound_service_account_names=argo,argo-server,argocd-server,default bound_service_account_namespaces=argo,argocd policies=k8s-secrets ttl=24h

#Deploy the setup.yml to k8s paralelle to this.

## GET number of vault pods
kubectl get pods -o=name | grep 'tooling-vault-[0-9]' | wc -l
