# MAS GitOps runbook

Use this after `INSTALL.md`. No helper script is required.

## Quick status

```bash
oc get applications -n openshift-gitops
oc get pods -n vault
oc get pods -n mongo-gitops
oc get jobs -n ibm-software-central
oc get jobs -n mas-drgitopsapp-sls
oc get licenseservices.sls.ibm.com -A
oc get suites.core.mas.ibm.com -A
oc get workspaces.core.mas.ibm.com -A
oc get mongocfgs,slscfgs,jdbccfgs,bascfgs.config.mas.ibm.com -A
oc get manageapps,manageworkspaces -A
```

## The three independent components

There is no app-of-apps and no `installStage`. Each component is a standalone Argo CD
Application, deployed by its own script and coupled only through Vault secret paths:

| Component | Application(s) | Deployed by |
|---|---|---|
| Operators | `operators` (cert-manager, grafana-op) | `bootstrap/05-operators.sh` |
| Vault | `vault` | `bootstrap/10-vault.sh` |
| MongoDB | `mongodb-operator`, `mongodb` | `bootstrap/20-mongodb.sh` |
| MAS | `ibm-mas-account-root` (+ IBM-generated tree) | `bootstrap/30-mas.sh` |

**cert-manager not ready** (Mongo/MAS scripts fail with "cert-manager CRD not found"): the
Red Hat cert-manager operator install is still in progress or stuck. Check:

```bash
oc get subscription,csv,installplan -n cert-manager-operator
oc get crd | grep cert-manager.io          # certificates.cert-manager.io must exist
oc get pods -n cert-manager                 # the operator deploys cert-manager here
```

If the CSV is `Installing` for a long time, approve a pending InstallPlan (grafana-operator uses
`Manual` approval by design). Once `certificates.cert-manager.io` exists, re-run `20-mongodb.sh`.

One-glance health of all three:

```bash
./scripts/status.sh <env>
oc get applications -n openshift-gitops -l app.kubernetes.io/part-of=mas-platform
```

Because the components are independent (and `prune` is `false` on Vault + Mongo), you can
redeploy any one without touching the others — e.g. `oc delete application ibm-mas-account-root`
then re-run `30-mas.sh` rebuilds only MAS. Force an immediate Git refresh of one component:

```bash
oc annotate application <vault|mongodb|ibm-mas-account-root> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Vault is sealed

Check every node:

```bash
oc exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 vault status
oc exec -n vault vault-1 -- env VAULT_ADDR=http://127.0.0.1:8200 vault status
oc exec -n vault vault-2 -- env VAULT_ADDR=http://127.0.0.1:8200 vault status
```

An authorized operator must apply three different unseal shares to each sealed pod, as
shown in `INSTALL.md`. Never reconstruct or store the shares in the cluster.

## AVP cannot resolve a placeholder

```bash
oc get deployment openshift-gitops-repo-server -n openshift-gitops \
  -o jsonpath='{.spec.template.spec.serviceAccountName}{"\n"}'
oc logs deployment/openshift-gitops-repo-server -n openshift-gitops -c avp-helm --tail=200
oc get configmap cmp-plugin -n openshift-gitops -o yaml
oc get secret gitlab-gitops-group-repo-creds -n openshift-gitops
```

Verify in Vault:

- Kubernetes auth role `mas-gitops` binds the displayed repo-server service account.
- The namespace is `openshift-gitops`.
- The role includes policy `mas-gitops`.
- The requested path and field exist with exactly the same spelling and scope.
- Vault is unsealed and `vault-active.vault.svc.cluster.local:8200` is reachable.

## MongoDB is not Running

```bash
oc get mongodbcommunity drgitopsapp-mongo -n mongo-gitops -o yaml
oc get pods,pvc,certificate,secret -n mongo-gitops
oc logs deployment/mongodb-kubernetes-operator -n mongo-gitops --tail=200
oc get events -n mongo-gitops --sort-by=.lastTimestamp
```

Check that:

- `mongo-ca` contains a matching base64 certificate/private-key pair.
- `mongo` and `sls-mongo` contain the same CA certificate as raw PEM.
- `isilon` can provision all data and log PVCs.
- The operator and database service accounts can use `nonroot-v2`.
- The configured IBM Mongo image tag exists and can be pulled.

## DRO registration is missing

```bash
oc get jobs -n ibm-software-central | grep postsync-ibm-dro-update-sm
DRO_JOB="$(oc get jobs -n ibm-software-central -o name | grep postsync-ibm-dro-update-sm | tail -1)"
oc logs -n ibm-software-central "$DRO_JOB" --all-containers --tail=200
oc get route ibm-data-reporter -n ibm-software-central
```

The completed Job must write:

```text
secret/drroc4/drroc4/dro
fields: url, api_token, ca.crt
```

Vault role `mas-gitops-writer` must bind `postsync-ibm-dro-update-sm-sa` in
`ibm-software-central`.

## SLS registration is missing

```bash
oc get licenseservices.sls.ibm.com -A
oc get configmap sls-suite-registration -n mas-drgitopsapp-sls
oc get jobs -n mas-drgitopsapp-sls | grep postsync-ibm-sls-update-sm
SLS_JOB="$(oc get jobs -n mas-drgitopsapp-sls -o name | grep postsync-ibm-sls-update-sm | tail -1)"
oc logs -n mas-drgitopsapp-sls "$SLS_JOB" --all-containers --tail=200
```

The completed Job must write:

```text
secret/drroc4/drroc4/drgitopsapp/sls
fields: registration_key, url, ca.crt
```

Vault role `mas-gitops-writer` must bind `postsync-ibm-sls-update-sm-sa` in
`mas-drgitopsapp-sls`.

## A MAS system configuration is not Ready

```bash
oc describe mongocfg drgitopsapp-mongo-system -n mas-drgitopsapp-core
oc describe slscfg drgitopsapp-sls-system -n mas-drgitopsapp-core
oc describe jdbccfg drgitopsapp-jdbc-system -n mas-drgitopsapp-core
oc describe bascfg drgitopsapp-bas-system -n mas-drgitopsapp-core
```

Common checks:

- `MongoCfg`: host, credentials, and CA match the dedicated MongoDB service.
- `SlsCfg`: the SLS runtime path exists and contains raw PEM under `ca.crt`.
- `JdbcCfg`: Oracle URL is reachable and `sslEnabled` renders `false`.
- `BasCfg`: it reads cluster path `secret/drroc4/drroc4/dro`, not an instance path.

Hard-refresh the affected Argo CD Application after correcting a Vault value:

```bash
oc annotate application <application-name> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Certificate failure

```bash
oc get secret drgitopsapp-cert-public -n mas-drgitopsapp-core -o yaml
oc get secret drgitopsapp-drgitopswks-cert-public-81 -n mas-drgitopsapp-manage -o yaml
oc describe suite drgitopsapp -n mas-drgitopsapp-core
oc get routes -n mas-drgitopsapp-core
oc get routes -n mas-drgitopsapp-manage
```

Each Vault `*_b64` field must decode once to PEM. Confirm locally without printing the
private key:

```bash
printf '%s' '<tls_crt_b64>' | base64 -d | openssl x509 -noout -subject -issuer -dates
```

The Suite chart owns the core certificate Secret; the Manage install chart owns the
Manage certificate Secret. No custom certificate Application should exist.

## Suite or Manage is not Ready

```bash
oc describe suite drgitopsapp -n mas-drgitopsapp-core
oc get manageapp,manageworkspace -n mas-drgitopsapp-manage
oc describe manageapp drgitopsapp -n mas-drgitopsapp-manage
oc describe manageworkspace drgitopsapp-drgitopswks -n mas-drgitopsapp-manage
oc get pods -n mas-drgitopsapp-manage
```

Do not troubleshoot Manage until all four system configurations and the Suite are Ready.
For a fresh database, `autoGenerateEncryptionKeys` must remain `true`. A reused database
requires its original encryption keys and is a different recovery procedure.

## Vault backup

Take an encrypted, access-controlled Raft snapshot after initial seed and after material
secret changes:

```bash
oc exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault operator raft snapshot save /tmp/drroc4.snap
oc cp vault/vault-0:/tmp/drroc4.snap "$HOME/drroc4-vault.snap"
oc exec -n vault vault-0 -- rm -f /tmp/drroc4.snap
```

Move the snapshot to approved backup storage. A snapshot does not replace the separated
unseal-key shares.
