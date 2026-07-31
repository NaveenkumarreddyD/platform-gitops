# IBM's patched jobs may write only their generated runtime registrations.
# Segments are <account>/<cluster>/<instance>. The account segment is wildcarded ("+")
# so this one file serves any env (mas, roc4, doc4, ...) on its own single-tenant Vault.
# SLS is instance scoped; DRO is cluster scoped.
path "secret/data/+/+/+/sls"       { capabilities = ["create", "update", "read"] }
path "secret/data/+/+/dro"         { capabilities = ["create", "update", "read"] }
path "secret/metadata/+/+/+/sls"   { capabilities = ["read"] }
path "secret/metadata/+/+/dro"     { capabilities = ["read"] }
