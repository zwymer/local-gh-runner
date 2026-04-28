#!/usr/bin/dumb-init /bin/bash
# shellcheck shell=bash

export RUNNER_ALLOW_RUNASROOT=1
export PATH=${PATH}:/actions-runner

# Un-export these, so that they must be passed explicitly to the environment of
# any command that needs them.  This may help prevent leaks.
export -n ACCESS_TOKEN
export -n RUNNER_TOKEN
export -n APP_ID
export -n APP_PRIVATE_KEY

trap_with_arg() {
    func="$1" ; shift
    for sig ; do
        # shellcheck disable=SC2064
        trap "$func $sig" "$sig"
    done
}

deregister_runner() {
  echo "Caught $1 - Deregistering runner"
  if [[ -n "${ACCESS_TOKEN}" ]]; then
    # If using GitHub App authentication, refresh the access token before deregistration
    if [[ -n "${APP_ID}" ]] && [[ -n "${APP_PRIVATE_KEY}" ]] && [[ -n "${APP_LOGIN}" ]]; then
      echo "Refreshing access token for deregistration"
      nl="
"
      NEW_ACCESS_TOKEN=$(APP_ID="${APP_ID}" APP_PRIVATE_KEY="${APP_PRIVATE_KEY//\\n/${nl}}" APP_LOGIN="${APP_LOGIN}" bash /app_token.sh)
      if [[ -z "${NEW_ACCESS_TOKEN}" ]] || [[ "${NEW_ACCESS_TOKEN}" == "null" ]]; then
        echo "ERROR: Failed to refresh access token for deregistration"
        exit 1
      fi
      ACCESS_TOKEN="${NEW_ACCESS_TOKEN}"
      echo "Access token refreshed successfully"
    fi
    _TOKEN=$(ACCESS_TOKEN="${ACCESS_TOKEN}" bash /token.sh)
    RUNNER_TOKEN=$(echo "${_TOKEN}" | jq -r .token)
  fi
  ./config.sh remove --token "${RUNNER_TOKEN}"
  [[ -f "/actions-runner/.runner" ]] && rm -f /actions-runner/.runner
  exit
}

_DEBUG_ONLY=${DEBUG_ONLY:-false}
_DEBUG_OUTPUT=${DEBUG_OUTPUT:-false}
_DISABLE_AUTOMATIC_DEREGISTRATION=${DISABLE_AUTOMATIC_DEREGISTRATION:-false}

_RANDOM_RUNNER_SUFFIX=${RANDOM_RUNNER_SUFFIX:="true"}

_RUNNER_NAME=${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-github-runner}-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 ; echo '')}
if [[ ${RANDOM_RUNNER_SUFFIX} != "true" ]]; then
  if [[ -f "/etc/hostname" ]]; then
    if [[ $(stat --printf="%s" /etc/hostname) -ne 0 ]]; then
      _RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX-"github-runner"}
      _RUNNER_NAME=${RUNNER_NAME:-${_RUNNER_NAME_PREFIX:+${_RUNNER_NAME_PREFIX}-}$(cat /etc/hostname)}
    fi
  fi
fi

_RUNNER_WORKDIR=${RUNNER_WORKDIR:-/_work/${_RUNNER_NAME}}
_LABELS=${RUNNER_LABELS:-${LABELS:-default}}
_RUNNER_GROUP=${RUNNER_GROUP:-Default}
_GITHUB_HOST=${GITHUB_HOST:="github.com"}
_RUN_AS_ROOT=${RUN_AS_ROOT:="true"}
_START_DOCKER_SERVICE=${START_DOCKER_SERVICE:="false"}
_UNSET_CONFIG_VARS=${UNSET_CONFIG_VARS:="false"}
_CONFIGURED_ACTIONS_RUNNER_FILES_DIR=${CONFIGURED_ACTIONS_RUNNER_FILES_DIR:-""}

# ensure backwards compatibility
if [[ -z ${RUNNER_SCOPE} ]]; then
  if [[ ${ORG_RUNNER} == "true" ]]; then
    export RUNNER_SCOPE="org"
  else
    export RUNNER_SCOPE="repo"
  fi
fi

RUNNER_SCOPE="${RUNNER_SCOPE,,}" # to lowercase

case ${RUNNER_SCOPE} in
  org*)
    [[ -z ${ORG_NAME} ]] && ( echo "ORG_NAME required for org runners"; exit 1 )
    _SHORT_URL="https://${_GITHUB_HOST}/${ORG_NAME}"
    RUNNER_SCOPE="org"
    if [[ -n "${APP_ID}" ]] && [[ -z "${APP_LOGIN}" ]]; then
      APP_LOGIN=${ORG_NAME}
    fi
    ;;

  ent*)
    [[ -z ${ENTERPRISE_NAME} ]] && ( echo "ENTERPRISE_NAME required for enterprise runners"; exit 1 )
    _SHORT_URL="https://${_GITHUB_HOST}/enterprises/${ENTERPRISE_NAME}"
    RUNNER_SCOPE="enterprise"
    ;;

  *)
    [[ -z ${REPO_URL} ]] && ( echo "REPO_URL required for repo runners"; exit 1 )
    _SHORT_URL=${REPO_URL}
    RUNNER_SCOPE="repo"
    if [[ -n "${APP_ID}" ]] && [[ -z "${APP_LOGIN}" ]]; then
      APP_LOGIN=${REPO_URL%/*}
      APP_LOGIN=${APP_LOGIN##*/}
    fi
    ;;
esac

configure_runner() {
  ARGS=()
  if [[ -n "${APP_ID}" ]] && [[ -n "${APP_PRIVATE_KEY}" ]] && [[ -n "${APP_LOGIN}" ]]; then
    if [[ -n "${ACCESS_TOKEN}" ]] || [[ -n "${RUNNER_TOKEN}" ]]; then
      echo "ERROR: ACCESS_TOKEN or RUNNER_TOKEN provided but are mutually exclusive with APP_ID, APP_PRIVATE_KEY and APP_LOGIN." >&2
      exit 1
    fi
    echo "Obtaining access token for app_id ${APP_ID} and login ${APP_LOGIN}"
    nl="
"
    ACCESS_TOKEN=$(APP_ID="${APP_ID}" APP_PRIVATE_KEY="${APP_PRIVATE_KEY//\\n/${nl}}" APP_LOGIN="${APP_LOGIN}" bash /app_token.sh)
  elif [[ -n "${APP_ID}" ]] || [[ -n "${APP_PRIVATE_KEY}" ]] || [[ -n "${APP_LOGIN}" ]]; then
    echo "ERROR: All of APP_ID, APP_PRIVATE_KEY and APP_LOGIN must be specified." >&2
    exit 1
  fi

  if [[ -n "${ACCESS_TOKEN}" ]]; then
    echo "Obtaining the token of the runner"
    _TOKEN=$(ACCESS_TOKEN="${ACCESS_TOKEN}" bash /token.sh)
    RUNNER_TOKEN=$(echo "${_TOKEN}" | jq -r .token)
  fi

  if [ -n "${EPHEMERAL}" ]; then
    echo "Ephemeral option is enabled"
    ARGS+=("--ephemeral")
  fi

  if [ -n "${DISABLE_AUTO_UPDATE}" ]; then
    echo "Disable auto update option is enabled"
    ARGS+=("--disableupdate")
  fi

  if [ -n "${NO_DEFAULT_LABELS}" ]; then
    echo "Disable adding the default self-hosted, platform, and architecture labels"
    ARGS+=("--no-default-labels")
  fi

  echo "Configuring"
  ./config.sh \
      --url "${_SHORT_URL}" \
      --token "${RUNNER_TOKEN}" \
      --name "${_RUNNER_NAME}" \
      --work "${_RUNNER_WORKDIR}" \
      --labels "${_LABELS}" \
      --runnergroup "${_RUNNER_GROUP}" \
      --unattended \
      --replace \
      "${ARGS[@]}"

  [[ ! -d "${_RUNNER_WORKDIR}" ]] && mkdir -p "${_RUNNER_WORKDIR}"
}

unset_config_vars() {
  unset RUN_AS_ROOT RUNNER_NAME RUNNER_NAME_PREFIX RANDOM_RUNNER_SUFFIX
  unset ACCESS_TOKEN APP_ID APP_PRIVATE_KEY APP_LOGIN
  unset RUNNER_SCOPE ORG_NAME ENTERPRISE_NAME LABELS REPO_URL RUNNER_TOKEN
  unset RUNNER_WORKDIR RUNNER_GROUP GITHUB_HOST
  unset DISABLE_AUTOMATIC_DEREGISTRATION CONFIGURED_ACTIONS_RUNNER_FILES_DIR
  unset EPHEMERAL DISABLE_AUTO_UPDATE START_DOCKER_SERVICE NO_DEFAULT_LABELS
  unset UNSET_CONFIG_VARS
}

# Opt into runner reusage because a value was given
if [[ -n "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}" ]]; then
  echo "Runner reusage is enabled"
  if [[ -d "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}" ]]; then
    echo "Copying previous data"
    cp -p -r "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}/." "/actions-runner"
  fi

  if [ -f "/actions-runner/.runner" ]; then
    echo "The runner has already been configured"
  else
    if [[ ${_DEBUG_ONLY} == "false" ]]; then
      configure_runner
    fi
  fi
else
  echo "Runner reusage is disabled"
  if [[ ${_DEBUG_ONLY} == "false" ]]; then
    [[ -f "/actions-runner/.runner" ]] && rm -f /actions-runner/.runner
    configure_runner
  fi
fi

if [[ -n "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}" ]]; then
  echo "Reusage is enabled. Storing data to ${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}"
  if [[ ${_DISABLE_AUTOMATIC_DEREGISTRATION} == "false" ]]; then
    echo "DISABLE_AUTOMATIC_DEREGISTRATION should be set to true to avoid issues with re-using a deregistered runner."
    exit 1
  fi
  cp -p -r "/actions-runner/_diag" "/actions-runner/svc.sh" /actions-runner/.[^.]* "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}"
fi

if [[ ${_DISABLE_AUTOMATIC_DEREGISTRATION} == "false" ]]; then
  if [[ ${_DEBUG_ONLY} == "false" ]]; then
    trap_with_arg deregister_runner SIGINT SIGQUIT SIGTERM INT TERM QUIT
  fi
fi

if [[ ${_START_DOCKER_SERVICE} == "true" ]]; then
  echo "Starting docker service"
  _PREFIX=""
  [[ ${_RUN_AS_ROOT} != "true" ]] && _PREFIX="sudo"
  if [[ ${_DEBUG_ONLY} == "false" ]]; then
    ${_PREFIX} service docker start
  fi
fi

if [[ ${_UNSET_CONFIG_VARS} == "true" ]]; then
  unset_config_vars
fi

# Container's command (CMD) execution as runner user
if [[ ${_RUN_AS_ROOT} == "true" ]]; then
  if [[ $(id -u) -eq 0 ]]; then
    if [[ ${_DEBUG_ONLY} == "false" ]]; then
      "$@"
    fi
  else
    echo "ERROR: RUN_AS_ROOT env var is set to true but the user is not root (UID=$(id -u))"
    exit 1
  fi
else
  if [[ $(id -u) -eq 0 ]]; then
    [[ -n "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}" ]] && chown -R runner "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}"
    chown runner /actions-runner "${_RUNNER_WORKDIR}"
    find /actions-runner -mindepth 1 -maxdepth 1 ! -name bin ! -name externals -exec chown -R runner {} + 2>/dev/null || true
    chown runner /opt/hostedtoolcache/
    if [[ ${_DEBUG_ONLY} == "false" ]]; then
      /usr/sbin/gosu runner "$@"
    fi
  else
    if [[ ${_DEBUG_ONLY} == "false" ]]; then
      "$@"
    fi
  fi
fi
