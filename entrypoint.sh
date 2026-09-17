#!/bin/bash
# entrypoint.sh — Loads Docker secrets from /run/secrets/ into environment
# variables, then execs the CMD.
#
# Docker secrets are mounted as files at /run/secrets/<secret_name>.
# This script reads each file and exports its contents as an environment
# variable with the uppercased filename.
#
# Example: /run/secrets/anthropic_api_key → ANTHROPIC_API_KEY=<contents>

set -euo pipefail

# ── Load secrets into environment ─────────────────────────────────────
SECRETS_DIR="/run/secrets"

if [ -d "$SECRETS_DIR" ]; then
    for secret_file in "$SECRETS_DIR"/*; do
        [ -f "$secret_file" ] || continue

        # Derive env var name: filename → UPPER_CASE
        secret_name="$(basename "$secret_file")"
        env_var_name="$(echo "$secret_name" | tr '[:lower:]' '[:upper:]')"

        # Read the secret value (trim trailing newline)
        secret_value="$(cat "$secret_file" | tr -d '\n')"

        export "$env_var_name"="$secret_value"
    done
fi

# ── Execute the CMD ───────────────────────────────────────────────────
exec "$@"
