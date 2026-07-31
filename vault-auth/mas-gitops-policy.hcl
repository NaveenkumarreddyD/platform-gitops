# AVP read policy. The first path segment is the ACCOUNT (mas, roc4, doc4, ...).
# Each env runs its own single-tenant Vault, so wildcarding the account segment ("+")
# lets this one file serve any env without per-env editing.
path "secret/data/+/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/+/*" {
  capabilities = ["read", "list"]
}
