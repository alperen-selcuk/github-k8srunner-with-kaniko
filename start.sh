#!/bin/bash
set -euo pipefail

# Two modes:
#   RUNNER_TOKEN  registration token from the repo UI (valid 1 hour). The runner registers once,
#                 its credentials are kept on the persistent volume and reused on every restart.
#   GITHUB_PAT    fine-grained PAT (Administration: read & write). A fresh registration token is
#                 fetched on every start, so the runner runs ephemeral (one job per registration)
#                 and unregisters itself on shutdown.

print_header() {
  lightcyan="\033[1;36m"
  nocolor="\033[0m"
  echo -e "\n${lightcyan}$1${nocolor}\n"
}

die() {
  echo 1>&2 "error: $1"
  exit 1
}

# GITHUB_URL control
[ -n "${GITHUB_URL:-}" ] || die "missing GITHUB_URL environment variable (https://github.com/<owner>/<repo>)"

# Token control
if [ -n "${GITHUB_PAT:-}" ]; then
  MODE=pat
elif [ -n "${RUNNER_TOKEN:-}" ]; then
  MODE=token
else
  die "missing GITHUB_PAT or RUNNER_TOKEN environment variable"
fi

# Keep tokens in non-exported shell variables so job steps do not inherit them
PAT="${GITHUB_PAT:-}"
REG_TOKEN="${RUNNER_TOKEN:-}"
unset GITHUB_PAT RUNNER_TOKEN

GITHUB_URL="${GITHUB_URL%/}"
RUNNER_HOME="${RUNNER_HOME:-/runner}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-${RUNNER_HOME}/_work}"
RUNNER_LABELS="${RUNNER_LABELS:-}"
RUNNER_GROUP="${RUNNER_GROUP:-}"
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_NAME_PREFIX:+${RUNNER_NAME_PREFIX}-}$(hostname)}"

if [ "${MODE}" = "pat" ]; then
  RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-true}"
else
  # An ephemeral runner drops its registration after one job; re-registering would need a new 1-hour token
  if [ "${RUNNER_EPHEMERAL:-false}" = "true" ]; then
    echo "warning: RUNNER_EPHEMERAL ignored in RUNNER_TOKEN mode, use GITHUB_PAT for ephemeral runners"
  fi
  RUNNER_EPHEMERAL=false
fi

# https://github.com/<owner>/<repo> -> repos/<owner>/<repo>, https://github.com/<org> -> orgs/<org>
GITHUB_HOST="$(echo "${GITHUB_URL}" | cut -d/ -f3)"
GITHUB_PATH="$(echo "${GITHUB_URL}" | cut -d/ -f4-)"
if [ "${GITHUB_HOST}" = "github.com" ]; then
  API_URL="https://api.github.com"
else
  API_URL="https://${GITHUB_HOST}/api/v3"
fi
case "${GITHUB_PATH}" in
  */*) API_SCOPE="repos/${GITHUB_PATH}" ;;
  *)   API_SCOPE="orgs/${GITHUB_PATH}" ;;
esac

# $1: registration-token | remove-token
fetch_token() {
  local token
  token=$(curl -fsSL -X POST \
    -H "Authorization: Bearer ${PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_URL}/${API_SCOPE}/actions/runners/$1" | jq -r .token)
  if [ -z "${token}" ] || [ "${token}" = "null" ]; then
    echo 1>&2 "error: could not get $1 from ${API_URL}/${API_SCOPE}, check GITHUB_URL and that the PAT has Administration (read & write)"
    return 1
  fi
  echo "${token}"
}

RUNNER_PID=""

cleanup() {
  trap "" EXIT INT TERM

  if [ -n "${RUNNER_PID}" ]; then
    # run.sh is only a wrapper; the listener must get the signal itself to close its
    # GitHub session, otherwise the next start fails with "A session for this runner already exists"
    pkill -TERM -f "${RUNNER_HOME}/bin/Runner.Listener" 2>/dev/null || true
    wait "${RUNNER_PID}" 2>/dev/null || true
  fi

  # RUNNER_TOKEN mode keeps the registration so the pod can come back after a restart
  if [ "${MODE}" = "pat" ] && [ -f "${RUNNER_HOME}/.runner" ]; then
    print_header "Cleanup. Removing GitHub runner ${RUNNER_NAME}..."
    for _ in 1 2 3; do
      ./config.sh remove --token "$(fetch_token remove-token)" && break
      echo "Retrying in 10 seconds..."
      sleep 10
    done
  fi
}

print_header "1. Preparing GitHub Actions runner in ${RUNNER_HOME}..."

mkdir -p "${RUNNER_HOME}"
# Copy only once; runner self-updates write into the volume and survive restarts
if [ ! -x "${RUNNER_HOME}/config.sh" ]; then
  cp -a /opt/actions-runner/. "${RUNNER_HOME}/"
fi
cd "${RUNNER_HOME}"

if [ "${RUNNER_EPHEMERAL}" = "true" ]; then
  # Every ephemeral run starts clean: new registration, empty workspace
  rm -f .runner .credentials .credentials_rsaparams
  rm -rf "${RUNNER_WORKDIR}"
fi
mkdir -p "${RUNNER_WORKDIR}"

on_exit() {
  local rc=$?
  cleanup
  exit "${rc}"
}

trap on_exit EXIT
trap "cleanup; exit 130" INT
trap "cleanup; exit 143" TERM

if [ -f .runner ]; then
  print_header "2. Runner already registered, reusing existing registration..."
else
  print_header "2. Configuring GitHub runner ${RUNNER_NAME} for ${GITHUB_URL}..."

  if [ "${MODE}" = "pat" ]; then
    REG_TOKEN="$(fetch_token registration-token)"
  fi

  args=(
    --unattended
    --url "${GITHUB_URL}"
    --token "${REG_TOKEN}"
    --name "${RUNNER_NAME}"
    --work "${RUNNER_WORKDIR}"
    --replace
  )
  [ -n "${RUNNER_LABELS}" ] && args+=(--labels "${RUNNER_LABELS}")
  [ -n "${RUNNER_GROUP}" ] && args+=(--runnergroup "${RUNNER_GROUP}")
  [ "${RUNNER_EPHEMERAL}" = "true" ] && args+=(--ephemeral)

  if ! ./config.sh "${args[@]}"; then
    if [ "${MODE}" = "token" ]; then
      echo 1>&2 "error: registration failed. RUNNER_TOKEN is valid for 1 hour only; put a new token into the secret and restart the pod"
    fi
    exit 1
  fi
fi

print_header "3. Running GitHub runner..."

./run.sh "$@" &
RUNNER_PID=$!
wait "${RUNNER_PID}"
RUNNER_PID=""

# An ephemeral runner has already unregistered itself after its job
if [ "${RUNNER_EPHEMERAL}" = "true" ]; then
  rm -f .runner
fi
