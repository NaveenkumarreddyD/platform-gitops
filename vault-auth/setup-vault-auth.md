> UPDATE: setup-vault-auth.sh now defaults to NO-EXPIRY k8s auth (Vault reviews tokens with its own
> auto-rotated pod SA token; the Vault SA gets system:auth-delegator). No more 24h reviewer-JWT breakage.
> Legacy static reviewer JWT: STATIC_REVIEWER_JWT=1 ./setup-vault-auth.sh

# Vault post-install setup for MAS GitOps

Vault initialization and unseal must remain manual/security-controlled.

## Manual steps

```bash
oc exec -n vault vault-0 -- vault operator init
oc exec -n vault vault-0 -- vault operator unseal '<KEY1>'
oc exec -n vault vault-0 -- vault operator unseal '<KEY2>'
oc exec -n vault vault-0 -- vault operator unseal '<KEY3>'
```

Join/unseal vault-1 and vault-2 if they are not joined:

```bash
oc exec -n vault vault-1 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault operator raft join http://vault-0.vault-internal:8200'
oc exec -n vault vault-2 -- sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault operator raft join http://vault-0.vault-internal:8200'
```

Then run:

```bash
export VAULT_TOKEN='<root-or-admin-token>'
export REPO_SA=default
./vault-auth/setup-vault-auth.sh
```
