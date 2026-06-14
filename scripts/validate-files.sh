#!/usr/bin/env bash
set -euo pipefail
parser=""
if python3 - <<'PY' >/dev/null 2>&1
import yaml
PY
then
  parser=python
elif ruby -e 'require "yaml"' >/dev/null 2>&1; then
  parser=ruby
else
  echo "ERROR: need Python PyYAML or Ruby YAML to validate YAML files" >&2
  exit 1
fi

while IFS= read -r -d '' f; do
  if grep -q '{{' "$f"; then
    echo "skip templated $f"
    continue
  fi
  case "$parser" in
    python) python3 -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1]))); print("ok " + sys.argv[1])' "$f" ;;
    ruby) ruby -e 'require "yaml"; YAML.load_file(ARGV[0]); puts "ok #{ARGV[0]}"' "$f" ;;
  esac
done < <(find . \( -name '*.yaml' -o -name '*.yml' \) -print0)
