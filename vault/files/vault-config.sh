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



while true; do sleep 10; done;


# set +x
# while ! nslookup vault </dev/null || ! nc -w1 vault 8200 </dev/null; do
#     echo "Waiting for Vault to Come up!"
#     sleep 5
# done
# sleep 10

# echo "Vault Up, Will be initlising the it"

# export VAULT_ADDR=http://$VAULT_SERVICE_HOST:$VAULT_SERVICE_PORT_HTTP
# echo "vault address is: $VAULT_ADDR"

# echo "Initialising the vault"
# vault operator init -n 1 -t 1 > /tmp/stdout
# cat /tmp/stdout | head -n 1 | awk '{print $4}' > /tmp/key
# cat /tmp/stdout | grep -i "Root" |awk '{print $4}' > /tmp/token
# export KEY=$(cat /tmp/key)
# export VAULT_TOKEN=$(cat /tmp/token)

# echo "vault key is : $KEY"
# echo "vault token is : $VAULT_TOKEN"

# echo "Unsealing the vault"
# vault operator unseal $KEY
# vault status

# if [ "{{.Values.initvault.ldapauth.enabled}}" == "true" ]; then
#     echo "Enabling the LDAP auth"
#     export ldap_url="{{.Values.initvault.ldapauth.ldap_url}}"
#     export userattr="{{.Values.initvault.ldapauth.userattr}}"
#     export userdn="{{.Values.initvault.ldapauth.userdn}}"
#     export groupdn="{{.Values.initvault.ldapauth.groupdn}}"
#     export upndomain="{{.Values.initvault.ldapauth.upndomain}}"
#     vault auth enable ldap
#     vault login $VAULT_TOKEN
#     vault write auth/ldap/config \
#         url="${ldap_url}" \
#         userattr="${userattr}" \
#         userdn="${userdn}" \
#         groupdn="${groupdn}" \
#         upndomain="${upndomain}" \
#         insecure_tls=true starttls=true \
#         tls_min_version=tls10
# fi