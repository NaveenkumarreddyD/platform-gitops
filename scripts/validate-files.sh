#!/usr/bin/env bash
set -euo pipefail
for f in $(find . -name '*.yaml' -o -name '*.yml'); do
  python3 -c "import yaml; list(yaml.safe_load_all(open('$f'))); print('ok $f')"
done
