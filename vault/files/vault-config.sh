#!/bin/bash
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
vault operator init -format=json > cluster-keys.json || true;
sleep 5;

echo "Checking if keys exists"
if [ -s cluster-keys.json ]; 
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
		echo "Unsealing vault-$i";
		if vault operator unseal $(cat cluster-keys.json | jq -r ".unseal_keys_b64[$j]");
		then 
			sleep 10;
		else
			exit 71;
		fi
	done
	sleep 10;
done
