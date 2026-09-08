# MAS Quick Install — steps with the "why"

Simple end-to-end install for **cluster `drroc4`, instance `drgitopsapp`, workspace `drgitopswks`**.
Each command block has a `# why:` comment so you know what it's for. Full detail lives in
[INSTALL.md](INSTALL.md); day-2 fixes in [RUNBOOK.md](RUNBOOK.md).

Repos & branches this uses:
- `platform-gitops` @ `static-keys` — bootstrap + workloads (what you run)
- `mas-gitops-config` @ `codex/aws-secrets-manager` — env config, rendered by Argo CD
- `ibm-mas-gitops` (fork) @ `8.5.0-jdbc-patch` — stock IBM 8.5.0 + one JDBC patch

---

## 0. Before you start
```bash
# why: these tools are used by the scripts and by AVP.
oc version && helm version && git --version && openssl version && jq --version && aws --version && python3 --version

# why: you must be logged in; the OpenShift GitOps (Argo CD) operator must already exist.
oc whoami
oc get argocd openshift-gitops -n openshift-gitops
```

## 1. Create two AWS IAM keys
```bash
# why: least privilege — one READ-only key for Argo CD, one WRITE key for the publishers.
aws iam create-user --user-name mas-drroc4-sm-reader
aws iam create-user --user-name mas-drroc4-sm-publisher
aws iam create-access-key --user-name mas-drroc4-sm-reader        # save the key pair
aws iam create-access-key --user-name mas-drroc4-sm-publisher     # save the key pair
# reader policy  : GetSecretValue/DescribeSecret on mas/drroc4/drroc4/*
# publisher policy: write-only on the dro/sls/mongo secrets (no Delete/List) — see INSTALL.md §1
```

## 2. Put the keys + repo credential into OpenShift
```bash
# why: Argo CD needs a credential to pull your private GitLab repos.
oc -n openshift-gitops create secret generic gitlab-gitops-group-repo-creds \
  --from-literal=type=git --from-literal=url=https://gitlab.lac1.biz/gitops \
  --from-literal=username='<deploy-user>' --from-literal=password='<deploy-token>' \
  --dry-run=client -o yaml | oc label --local -f - argocd.argoproj.io/secret-type=repo-creds -o yaml | oc apply -f -

# why: the AVP plugin reads AWS with this static key to resolve <path:> placeholders.
oc create secret generic aws-static-credentials -n openshift-gitops \
  --from-literal=region=us-east-1 --from-literal=aws_access_key_id=AKIA<reader> --from-literal=aws_secret_access_key=<secret>

# why: the publisher key is needed in BOTH namespaces — openshift-gitops (SLS/DRO) AND
#      mongo-gitops (the Mongo-CA publish job runs there).
for ns in openshift-gitops mongo-gitops; do
  oc create ns $ns 2>/dev/null || true
  oc create secret generic aws-static-credentials-publisher -n $ns \
    --from-literal=region=us-east-1 --from-literal=aws_access_key_id=AKIA<pub> --from-literal=aws_secret_access_key=<secret>
done
```

## 3. Seed the secrets into AWS Secrets Manager
```bash
# why: prepare the public TLS cert from your .pfx bundle (the seed script needs PEM files).
PW=$(cat drgitopsapp.apps.drroc4.pwd.txt)
openssl pkcs12 -in drgitopsapp.apps.drroc4.pfx -clcerts -nokeys -passin "pass:$PW" | openssl x509 -out tls.crt
cp drgitopsapp.apps.drroc4.decrypted.key tls.key
cat SubCA.cer RootCA.cer > ca-chain.crt

# why: never ship a cert whose SAN has the /maximo bug — confirm the Manage hosts are clean.
openssl x509 -in tls.crt -noout -ext subjectAltName

# why: create/update every secret MAS reads. mongo/sls-mongo get username+password (+host);
#      mongo#ca.crt, sls and dro are NOT seeded — they publish automatically later.
export REGION=us-east-1 CLUSTER=drroc4 INSTANCE=drgitopsapp
export ENTITLEMENT_KEY='<ibm-key>' LICENSE_FILE=./entitlement.lic
export MONGO_ADMIN_PASSWORD='<32-char>' SLS_MONGO_PASSWORD='<32-char>'
export JDBC_USERNAME=maximo JDBC_PASSWORD='<pw>' JDBC_URL='jdbc:oracle:thin:@//db:1521/MAXPDB'
export TLS_CRT=$PWD/tls.crt TLS_KEY=$PWD/tls.key CA_CHAIN=$PWD/ca-chain.crt
./scripts/seed-aws-secrets.sh
```

## 4. Render the config and preflight
```bash
# why: fill the templates with drroc4 values and push, so Argo CD can pull the rendered manifests.
cd ../mas-gitops-config && ./render.sh drroc4
git add -A && git commit -m "render drroc4" && git push

# why: catch id/prefix mismatches BEFORE anything is applied.
cd ../platform-gitops && ./scripts/preflight-consistency.sh drroc4
```

## 5. Run the bootstrap — in order (each step gates the next)
```bash
# why: wire Argo CD + the AVP sidecar so <path:> can be resolved from AWS.
./bootstrap/00-prereqs.sh drroc4

# why: install cert-manager — MongoDB (next) and MAS both need its CRDs.
./bootstrap/05-operators.sh drroc4
oc wait --for=condition=Established crd/certificates.cert-manager.io --timeout=10m

# why: MongoDB + cert-manager CA; this step WAITS until mongo#ca.crt is published so MAS can trust it.
./bootstrap/20-mongodb.sh drroc4

# why: deploy MAS — the account root fans out into Suite, SLS, DRO, Manage, workspace.
./bootstrap/30-mas.sh drroc4
```

## 6. Verify
```bash
# why: confirm every layer is up.
./scripts/status.sh drroc4
oc get certificate -n mongo-gitops                    # mongo-ca + -server = Ready
oc get suites.core.mas.ibm.com -A                     # Suite Ready
oc get manageapps,manageworkspaces -n mas-drgitopsapp-manage
oc get route -n mas-drgitopsapp-manage                # ...manage.drgitopsapp.apps.drroc4/maximo
```
**Done** when apps are Synced/Healthy, cfgs Ready, Suite + ManageWorkspace Ready, and the Manage route opens with a valid cert.

---

## Things that will bite you (and why)

- **`Warning: … prefer a domain-qualified finalizer name` / `last-applied-configuration`** — harmless Argo CD / `oc apply` chatter. Ignore. *Why: they're advisories, not errors; the scripts stop on real failures.*

- **`AWS Secrets Manager CMP is unavailable` right after `00-prereqs`** — the verify raced the repo-server rollout. Just re-run. *Why: `oc exec deployment/…` can hit the old, terminating pod; the fixed `verify` retries against a live pod.*

- **App `Synced/Healthy` but nothing created** — the AVP plugin rendered nothing. Check `oc logs deploy/openshift-gitops-repo-server -c avp-helm` for a `helm template` error (e.g. a stray character in the `cmp-plugin` ConfigMap). *Why: an empty render = Argo has nothing to apply, so it reports Synced + Healthy.*

- **`repository not found` / `not permitted in project 'mas'`** — the account-root's `source.repoURL` is wrong (e.g. `ibm-gitops.git` vs `ibm-mas-gitops.git`). *Why: that URL is baked into the app object; a Git push does NOT auto-fix it.* Fix `source.repo_url` in `values.yaml` + env `common.yaml` + `validate.yaml` + `02-argo-project.yaml`, then **re-apply the account root**:
  ```bash
  helm template platform gitops -f gitops/envs/drroc4/common.yaml -f gitops/envs/drroc4/values.yaml --set component=mas | oc apply -f -
  oc apply -f bootstrap/00-prereqs/02-argo-project.yaml
  oc annotate application ibm-mas-account-root -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
  ```

- **DRO published but not SLS** — SLS just takes longer to register. *Why: the publisher polls every 5 min and skips SLS until its `sls-suite-registration` ConfigMap exists; it catches up automatically.*

- **`Permission denied` on scripts** — a script lost its execute bit. Fix with `chmod +x bootstrap/*.sh scripts/*.sh`. *Why: never use `chmod =X` (it strips read and locks you out) — use `+x` / `u+rwX`.*

## The two "push-back" pieces (auto-created — don't seed)
| Value | Who writes it | Why it isn't seeded |
|---|---|---|
| `mongo#ca.crt` | cert-manager CA + the `-ca-publish` Job | the CA is generated in-cluster; only its public cert is pushed to AWS |
| `sls`, `dro` | `aws-generated-secrets-publisher` | SLS/DRO generate these at runtime; the publisher writes them to AWS (IBM's own write-back is off via `run_sync_hooks: false`) |
