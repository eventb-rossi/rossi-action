#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--version" ] && [ -n "${ROSSI_TEST_VERSION:-}" ]; then
  echo "rossi ${ROSSI_TEST_VERSION}"
  exit 0
fi
if [ "${1:-}" = "validate" ]; then
  echo validate >> "${ROSSI_VALIDATE_LOG:?}"
fi
exec "${ROSSI_REAL:?}" "$@"
