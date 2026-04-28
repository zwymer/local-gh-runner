#!/bin/bash
# Downloads and extracts the GitHub Actions runner for the given version
# and platform into /actions-runner.
#
# Usage: install_actions.sh <version> <platform>
#   e.g. install_actions.sh 2.334.0 linux/amd64

set -euo pipefail

GH_RUNNER_VERSION="$1"
TARGETPLATFORM="$2"

case "${TARGETPLATFORM}" in
  linux/amd64)  ARCH=x64   ;;
  linux/arm64)  ARCH=arm64 ;;
  *)            echo "Unsupported platform: ${TARGETPLATFORM}" >&2; exit 1 ;;
esac

RUNNER_URL="https://github.com/actions/runner/releases/download/v${GH_RUNNER_VERSION}/actions-runner-linux-${ARCH}-${GH_RUNNER_VERSION}.tar.gz"

echo "Downloading GitHub Actions runner v${GH_RUNNER_VERSION} for ${ARCH}..."
curl -fsSL "${RUNNER_URL}" -o /tmp/runner.tar.gz

mkdir -p /actions-runner /_work
tar -xzf /tmp/runner.tar.gz -C /actions-runner
rm /tmp/runner.tar.gz

# Install runner dependencies (.NET runtime, etc.)
if [[ -f /actions-runner/bin/installdependencies.sh ]]; then
  /actions-runner/bin/installdependencies.sh
fi

echo "GitHub Actions runner v${GH_RUNNER_VERSION} installed."
