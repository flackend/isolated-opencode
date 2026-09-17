#!/usr/bin/env bash
# run.sh — Launch an OpenCode sandbox container for a given project.
#
# Usage:
#   ./run.sh /path/to/your/project
#   ./run.sh ../other-project
#
# Prerequisites:
#   1. Build the image:    docker build -t opencode-sandbox .
#   2. Create the network: docker network create --driver bridge \
#                            --opt com.docker.network.bridge.enable_icc=false \
#                            --subnet=172.30.0.0/24 opencode-isolated
#   3. Create secrets dir: mkdir -p ~/.config/opencode/secrets/
#   4. Add API key files:  echo "sk-ant-..." > ~/.config/opencode/secrets/anthropic_api_key

set -euo pipefail

# ── Parse arguments ───────────────────────────────────────────────────
PROJECT_DIR="${1:?Usage: ./run.sh /path/to/project}"

# Resolve to absolute path
if [ -d "$PROJECT_DIR" ]; then
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
else
    echo "ERROR: Directory does not exist: $PROJECT_DIR" >&2
    exit 1
fi

PROJECT_NAME="$(basename "$PROJECT_DIR")"
CONTAINER_NAME="opencode-${PROJECT_NAME}"

# ── Persistent volume for OpenCode/herdr config & state ───────────────
VOLUME_NAME="opencode-home-${PROJECT_NAME}"

# ── Secrets directory ─────────────────────────────────────────────────
SECRETS_DIR="${HOME}/.config/opencode/secrets"

if [ ! -d "$SECRETS_DIR" ]; then
    echo "WARNING: Secrets directory not found: $SECRETS_DIR" >&2
    echo "  Create it and add API key files:" >&2
    echo "    mkdir -p $SECRETS_DIR" >&2
    echo "    echo 'sk-ant-...' > $SECRETS_DIR/anthropic_api_key" >&2
    echo "" >&2
fi

# ── Build secret mount flags ─────────────────────────────────────────
SECRET_MOUNTS=()
if [ -d "$SECRETS_DIR" ]; then
    for secret_file in "$SECRETS_DIR"/*; do
        [ -f "$secret_file" ] || continue
        secret_name="$(basename "$secret_file")"
        SECRET_MOUNTS+=(-v "${secret_file}:/run/secrets/${secret_name}:ro")
    done
fi

# ── Ensure the isolated network exists ────────────────────────────────
if ! docker network inspect opencode-isolated &>/dev/null; then
    echo "Creating isolated Docker network: opencode-isolated"
    docker network create \
        --driver bridge \
        --opt com.docker.network.bridge.enable_icc=false \
        --subnet=172.30.0.0/24 \
        opencode-isolated
fi

# ── Launch container ──────────────────────────────────────────────────
echo "Starting OpenCode sandbox for: $PROJECT_NAME"
echo "  Container:  $CONTAINER_NAME"
echo "  Workspace:  $PROJECT_DIR → /workspace"
echo "  Volume:     $VOLUME_NAME → /home/coder"
echo "  Secrets:    ${#SECRET_MOUNTS[@]} secret(s) mounted"
echo ""

docker run -it --rm \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    \
    `# ── Security hardening ──────────────────────────────────` \
    --read-only \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1000:1000 \
    --pids-limit 256 \
    --memory 4g \
    --cpus 2 \
    \
    `# ── Writable mounts (targeted exceptions to read-only) ─` \
    --tmpfs /tmp:rw,noexec,nosuid,size=512m \
    --tmpfs /run:rw,noexec,nosuid,size=64m \
    -v "$VOLUME_NAME":/home/coder \
    -v "$PROJECT_DIR":/workspace \
    \
    `# ── Secrets (mounted as read-only files) ────────────────` \
    "${SECRET_MOUNTS[@]}" \
    \
    `# ── Network isolation ───────────────────────────────────` \
    --network opencode-isolated \
    --dns 1.1.1.1 \
    --dns 8.8.8.8 \
    \
    opencode-sandbox
