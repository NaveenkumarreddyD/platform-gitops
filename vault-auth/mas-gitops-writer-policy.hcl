# Writer policy for the vault-registration-sync Jobs. Deliberately NARROW:
# it can write ONLY the runtime registration secrets (sls, dro, mongo, sls-mongo),
# not entitlement/license/superuser/jdbc (those stay read-only via the AVP role).
# 'patch' is needed because the mongo CA is patched into existing secrets (creds
# were written earlier by load-secrets.sh and must not be clobbered).
path "secret/data/mas/+/+/sls"       { capabilities = ["create","update","read"] }
path "secret/data/mas/+/+/dro"       { capabilities = ["create","update","read"] }
path "secret/data/mas/+/+/mongo"     { capabilities = ["create","update","read","patch"] }
path "secret/data/mas/+/+/sls-mongo" { capabilities = ["create","update","read","patch"] }
path "secret/metadata/mas/+/+/*"     { capabilities = ["read","list"] }
