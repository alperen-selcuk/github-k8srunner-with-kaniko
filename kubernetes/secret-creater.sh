#!/bin/bash
set -euo pipefail

# Creates or updates the runner secret. Re-run it to put a fresh RUNNER_TOKEN in place.

read -r -p "GITHUB_URL (https://github.com/<owner>/<repo>) : " URL
read -r -p "Token type [token|pat] (token = 1-hour registration token) : " TYPE
read -r -s -p "Token : " TOKEN
echo
read -r -p "KUBERNETES NAMESPACE : " NS
read -r -p "Kaniko registry config.json path (empty to skip) : " REGISTRY_CONFIG

case "${TYPE}" in
  token) KEY=RUNNER_TOKEN ;;
  pat)   KEY=GITHUB_PAT ;;
  *)     echo "error: token type must be 'token' or 'pat'"; exit 1 ;;
esac

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic gh-runner \
  --from-literal=GITHUB_URL="${URL}" \
  --from-literal="${KEY}=${TOKEN}" \
  -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -

if [ -n "${REGISTRY_CONFIG}" ]; then
  kubectl create secret generic registry-auth \
    --from-file=config.json="${REGISTRY_CONFIG}" \
    -n "${NS}" --dry-run=client -o yaml | kubectl apply -f -
fi
