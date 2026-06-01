# Read-only access for AVP to every cluster's MAS secrets (KV v2 under secret/mas/*)
path "secret/data/mas/*" {
  capabilities = ["read"]
}
path "secret/metadata/mas/*" {
  capabilities = ["read", "list"]
}
