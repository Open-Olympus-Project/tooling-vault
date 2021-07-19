#!/bin/bash
authMethodName=kubernetes
secretPath=k8s

KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
namespace=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
apk update -q
apk add -q wget jq

VAULTAMOUNT=$(wget -vO- -nv --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $KUBE_TOKEN" https://kubernetes.default/api/v1/namespaces/$namespace/pods/ | jq -e .items[].metadata.name | grep vault-[0-9] | wc -l)

for i in `seq 0 $(($VAULTAMOUNT-1))`;
do
    while [[ "$(wget -vO- -nv --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $KUBE_TOKEN" https://kubernetes.default/api/v1/namespaces/$namespace/pods/vault-$i | jq .status.phase)" == "Running" ]]; do echo "waiting for vault-$i" && sleep 5; done;
done

echo "Starting vault init";

VAULT_ADDR=http://$(wget -vO- -nv --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $KUBE_TOKEN" https://kubernetes.default/api/v1/namespaces/$namespace/pods/vault-0 | jq -r .status.podIP ):8200

echo "Vault-0's address is $VAULT_ADDR"

echo "trying to gen keys from vault-0"
vault operator init -format=json > /cluster-keys.json || true;
sleep 5;

echo "Checking if keys exists"
if [ -s /cluster-keys.json ]; 
then
	echo "Got the keys from vault-0";
	break;
else
	echo "Failed to get keys" >&2;
	exit 69;
fi
sleep 1;

VAULT0_ADDR=$VAULT_ADDR
echo "Unsealing vaults..";
for i in `seq 0 $(($VAULTAMOUNT-1))`;
do
	VAULT_ADDR=http://$(wget -vO- -nv --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $KUBE_TOKEN" https://kubernetes.default/api/v1/namespaces/$namespace/pods/vault-$i | jq -r .status.podIP ):8200
	if [ ! $i == 0 ]
	then 
		echo "Joining vault-$i";
		if ! vault operator raft join $VAULT0_ADDR;
		then
			exit 70;
		fi
		sleep 5;
	fi
	for j in `seq 0 2`;
	do
		echo "Unsealing vault-$i $j";
		if vault operator unseal $(cat /cluster-keys.json | jq -r ".unseal_keys_b64[$j]");
		then 
			sleep 10;
		else
			exit 71;
		fi
	done
	sleep 10;
done

echo "Done unsealing $VAULTAMOUNT pod(s)"
echo "Start working on enabeling the first KV-V2 store"

VAULT_ADDR=http://$(wget -vO- -nv --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $KUBE_TOKEN" https://kubernetes.default/api/v1/namespaces/$namespace/pods/vault-0 | jq -r .status.podIP ):8200

echo "Vault-0's address is $VAULT_ADDR"

root_token=$(cat /cluster-keys.json | jq -r '.root_token')
vault login $root_token -no-print=true 1>/dev/null

echo "Enabled secret engiene $secretPath"
vault secrets enable -path=$secretPath kv-v2;

echo "Enabled $authMethodName auth method"
vault auth enable $authMethodName;

echo "Writing $secretPath path policy"
vault policy write $secretPath-secrets - <<EOF
path "$secretPath/*" {
	capabilities = ["read"]
}
EOF

echo "Creating role for $secretPath"
vault write auth/$authMethodName/role/$secretPath-secrets bound_service_account_names=tooling-prometheus-server,argo,argo-server,argocd-server,default bound_service_account_namespaces=monitoring,argo,argocd policies=$secretPath-secrets ttl=24h;

echo "Fetching vault sa secret name"
VAULT_SA_SECRET_NAME=$(wget -vO- -nv --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $KUBE_TOKEN" https://kubernetes.default/api/v1/namespaces/$namespace/serviceaccounts/vault | jq -r -e '.secrets[] | select(.name | test("vault-token")) | .name');

echo "Getting token and crt"
SA_JWT_TOKEN=$(wget -vO- -nv --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $KUBE_TOKEN" https://kubernetes.default/api/v1/namespaces/$namespace/secrets/$VAULT_SA_SECRET_NAME | jq -r -e '.data.token' | base64 -d; echo);
SA_CA_CRT=$(wget -vO- -nv --ca-certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt --header "Authorization: Bearer $KUBE_TOKEN" https://kubernetes.default/api/v1/namespaces/$namespace/secrets/$VAULT_SA_SECRET_NAME | jq -r -e '.data."ca.crt"' | base64 -d; echo);

echo "Configuring auth path"
vault write auth/$authMethodName/config token_reviewer_jwt="$SA_JWT_TOKEN" kubernetes_host="https://kubernetes.default:443" kubernetes_ca_cert="$SA_CA_CRT"

echo "Putting the root_token and cluster_key.json into the vault"
vault kv put k8s/secrets/vault root_token=$root_token cluster_keys="$(cat /cluster-keys.json)";

cat /cluster-keys.json

exit 0