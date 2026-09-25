#!/usr/bin/env bash
# tests.sh — Automated verification suite for the OpenCode sandbox container.
#
# Runs a series of security and functionality checks against the built image
# and reports PASS/FAIL for each test.
#
# Usage:
#   ./tests.sh
#
# Prerequisites:
#   1. Build the image first: docker build -t opencode-sandbox .
#   2. Create the network:   (the script will create it if missing)

set -uo pipefail

# ── Constants ─────────────────────────────────────────────────────────
IMAGE="opencode-sandbox"
NETWORK="opencode-isolated"
PASS=0
FAIL=0
SKIP=0

# ── Colors ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Helpers ───────────────────────────────────────────────────────────
pass() {
    echo -e "  ${GREEN}✓ PASS${NC}  $1"
    ((PASS++))
}

fail() {
    echo -e "  ${RED}✗ FAIL${NC}  $1"
    [ -n "${2:-}" ] && echo -e "         ${RED}→ $2${NC}"
    ((FAIL++))
}

skip() {
    echo -e "  ${YELLOW}○ SKIP${NC}  $1"
    [ -n "${2:-}" ] && echo -e "         ${YELLOW}→ $2${NC}"
    ((SKIP++))
}

section() {
    echo ""
    echo -e "${CYAN}${BOLD}── $1 ──${NC}"
}

# Helper: run a command inside the container with all hardening flags
sandbox_run() {
    docker run --rm \
        --read-only \
        --security-opt no-new-privileges:true \
        --cap-drop ALL \
        --user 1000:1000 \
        --pids-limit 256 \
        --memory 4g \
        --cpus 2 \
        --tmpfs /tmp:rw,exec,nosuid,size=512m \
        --tmpfs /run:rw,noexec,nosuid,size=64m \
        --network "$NETWORK" \
        --dns 1.1.1.1 \
        --dns 8.8.8.8 \
        "$IMAGE" \
        "$@" 2>&1
}

# ══════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}OpenCode Sandbox — Verification Suite${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Prerequisite checks ───────────────────────────────────────────────
section "Prerequisites"

# Check image exists
if docker image inspect "$IMAGE" &>/dev/null; then
    pass "Image '$IMAGE' exists"
else
    fail "Image '$IMAGE' not found" "Run: docker build -t $IMAGE ."
    echo ""
    echo -e "${RED}Cannot continue without the image. Aborting.${NC}"
    exit 1
fi

# Ensure isolated network exists
if ! docker network inspect "$NETWORK" &>/dev/null; then
    echo "  Creating isolated network: $NETWORK"
    docker network create \
        --driver bridge \
        --opt com.docker.network.bridge.enable_icc=false \
        "$NETWORK" &>/dev/null
fi

if docker network inspect "$NETWORK" &>/dev/null; then
    pass "Network '$NETWORK' exists"
else
    fail "Network '$NETWORK' could not be created"
fi

# ── Security tests ────────────────────────────────────────────────────
section "Security — User & Privileges"

# Test 1: Non-root user
WHOAMI=$(sandbox_run whoami)
if [ "$WHOAMI" = "coder" ]; then
    pass "Runs as non-root user 'coder'"
else
    fail "Expected user 'coder', got '$WHOAMI'"
fi

# Test 2: UID is 1000
UID_CHECK=$(sandbox_run id -u)
if [ "$UID_CHECK" = "1000" ]; then
    pass "UID is 1000"
else
    fail "Expected UID 1000, got '$UID_CHECK'"
fi

# Test 3: Capabilities are dropped
CAP_EFF=$(sandbox_run cat /proc/1/status | grep -i "capeff" | awk '{print $2}')
if [ "$CAP_EFF" = "0000000000000000" ]; then
    pass "All capabilities dropped (CapEff = 0)"
else
    fail "Capabilities not fully dropped" "CapEff = $CAP_EFF"
fi

# Test 4: no-new-privileges
NO_NEW_PRIV=$(sandbox_run cat /proc/1/status | grep -i "NoNewPrivs" | awk '{print $2}')
if [ "$NO_NEW_PRIV" = "1" ]; then
    pass "no-new-privileges is enforced"
else
    fail "no-new-privileges not set" "NoNewPrivs = $NO_NEW_PRIV"
fi

section "Security — Filesystem"

# Test 5: Read-only root filesystem
RO_TEST=$(sandbox_run touch /test-read-only 2>&1 || true)
if echo "$RO_TEST" | grep -qi "read-only"; then
    pass "Root filesystem is read-only"
else
    fail "Root filesystem is NOT read-only" "$RO_TEST"
fi

# Test 6: /tmp is writable (tmpfs)
TMP_TEST=$(sandbox_run bash -c "echo test > /tmp/test-write && cat /tmp/test-write" 2>&1)
if [ "$TMP_TEST" = "test" ]; then
    pass "/tmp is writable (tmpfs)"
else
    fail "/tmp is not writable" "$TMP_TEST"
fi

# Test 7: /tmp has nosuid and /run has noexec
RUN_MOUNT_OPTS=$(sandbox_run grep " /run " /proc/mounts 2>&1 || true)
TMP_MOUNT_OPTS=$(sandbox_run grep " /tmp " /proc/mounts 2>&1 || true)
if echo "$RUN_MOUNT_OPTS" | grep -q "noexec"; then
    pass "/run has noexec flag"
else
    fail "/run does NOT have noexec flag" "$RUN_MOUNT_OPTS"
fi
if echo "$TMP_MOUNT_OPTS" | grep -q "nosuid"; then
    pass "/tmp has nosuid flag"
else
    fail "/tmp does NOT have nosuid flag" "$TMP_MOUNT_OPTS"
fi

section "Security — Dangerous Tools Absent"

# Test 8: No dangerous binaries
DANGEROUS_TOOLS=("docker" "sudo" "su" "nc" "ncat" "socat" "nmap" "ssh" "sshd" "iptables" "ip")
ALL_ABSENT=true
FOUND_TOOLS=""

for tool in "${DANGEROUS_TOOLS[@]}"; do
    WHICH_RESULT=$(sandbox_run which "$tool" 2>&1 || true)
    if echo "$WHICH_RESULT" | grep -q "^/"; then
        ALL_ABSENT=false
        FOUND_TOOLS="$FOUND_TOOLS $tool"
    fi
done

if $ALL_ABSENT; then
    pass "No dangerous tools found (docker, sudo, nc, socat, ssh, iptables, etc.)"
else
    fail "Dangerous tools found:$FOUND_TOOLS"
fi

# ── Network tests ─────────────────────────────────────────────────────
section "Network — Isolation & Egress"

# Test 9: Cannot reach host (host.docker.internal or gateway)
HOST_PING=$(sandbox_run bash -c "ping -c1 -W2 172.30.0.1" 2>&1 || true)
if echo "$HOST_PING" | grep -qi "operation not permitted\|unreachable\|denied\|100% packet loss"; then
    pass "Cannot reach host/gateway (ping blocked — caps dropped)"
else
    # Even if ping fails for other reasons, as long as it doesn't succeed
    if echo "$HOST_PING" | grep -qi "1 received\|1 packets received\|bytes from"; then
        fail "Can reach host gateway" "$HOST_PING"
    else
        pass "Cannot reach host/gateway (ping failed)"
    fi
fi

# Test 10: Internet egress works (HTTPS)
EGRESS_TEST=$(sandbox_run bash -c "curl -sf --max-time 10 -o /dev/null -w '%{http_code}' https://registry.npmjs.org/" 2>&1 || true)
if [ "$EGRESS_TEST" = "200" ]; then
    pass "Internet egress works (HTTPS to registry.npmjs.org)"
else
    # Any HTTP response means connectivity works, even 4xx
    if echo "$EGRESS_TEST" | grep -qE "^[0-9]{3}$"; then
        pass "Internet egress works (HTTP $EGRESS_TEST from registry.npmjs.org)"
    else
        fail "Internet egress failed" "$EGRESS_TEST"
    fi
fi

# Test 11: DNS resolution works
DNS_TEST=$(sandbox_run bash -c "nslookup github.com 1.1.1.1" 2>&1 || true)
if echo "$DNS_TEST" | grep -qi "address\|name:"; then
    pass "DNS resolution works"
else
    # Try alternative check
    CURL_DNS=$(sandbox_run bash -c "curl -sf --max-time 5 -o /dev/null https://github.com && echo ok" 2>&1 || true)
    if [ "$CURL_DNS" = "ok" ]; then
        pass "DNS resolution works (verified via curl)"
    else
        fail "DNS resolution may not work" "$DNS_TEST"
    fi
fi

# ── Tooling tests ─────────────────────────────────────────────────────
section "Tooling — Required Binaries"

REQUIRED_TOOLS=(
    "bash:Shell for OpenCode"
    "curl:HTTP client"
    "rg:Ripgrep for content search"
    "find:File pattern matching"
    "diff:File comparison"
    "jq:JSON processing"
    "php:PHP runtime"
    "node:Node.js runtime"
    "npm:Node package manager"
)

for entry in "${REQUIRED_TOOLS[@]}"; do
    tool="${entry%%:*}"
    desc="${entry##*:}"
    TOOL_PATH=$(sandbox_run which "$tool" 2>&1 || true)
    if echo "$TOOL_PATH" | grep -q "^/"; then
        pass "$tool — $desc"
    else
        fail "$tool not found — $desc"
    fi
done

section "Tooling — AI Coding Agents (OpenCode, Antigravity CLI, herdr)"

# Test: OpenCode installed
OC_CHECK=$(sandbox_run bash -c "opencode --version" 2>&1 || true)
if echo "$OC_CHECK" | grep -qiE "opencode|version|[0-9]+\.[0-9]+"; then
    pass "OpenCode installed ($OC_CHECK)"
else
    fail "OpenCode not found or not working" "$OC_CHECK"
fi

# Test: Antigravity CLI installed
AGY_CHECK=$(sandbox_run bash -c "agy --version" 2>&1 || true)
if echo "$AGY_CHECK" | grep -qiE "antigravity|agy|version|[0-9]+\.[0-9]+"; then
    pass "Antigravity CLI installed ($AGY_CHECK)"
else
    fail "Antigravity CLI not found or not working" "$AGY_CHECK"
fi

# Test: antigravity alias/symlink
AGY_LINK=$(sandbox_run which antigravity 2>&1 || true)
if echo "$AGY_LINK" | grep -q "^/"; then
    pass "antigravity alias available ($AGY_LINK)"
else
    fail "antigravity alias not found" "$AGY_LINK"
fi

# Test: herdr installed
HERDR_CHECK=$(sandbox_run bash -c "herdr --version" 2>&1 || true)
if echo "$HERDR_CHECK" | grep -qiE "herdr|version|[0-9]+\.[0-9]+"; then
    pass "herdr installed ($HERDR_CHECK)"
else
    fail "herdr not found or not working" "$HERDR_CHECK"
fi

# ── Git exclusion test ────────────────────────────────────────────────
section "Tooling — Excluded (by design)"

GIT_CHECK=$(sandbox_run which git 2>&1 || true)
if echo "$GIT_CHECK" | grep -q "^/"; then
    fail "git should NOT be installed (user manages git outside container)"
else
    pass "git is excluded (as intended)"
fi

# ── Secrets test ──────────────────────────────────────────────────────
section "Secrets"

# Create a temporary test secret
TEST_SECRET_DIR=$(mktemp -d)
echo "test-secret-value" > "$TEST_SECRET_DIR/test_api_key"

SECRET_TEST=$(docker run --rm \
    --read-only \
    --security-opt no-new-privileges:true \
    --cap-drop ALL \
    --user 1000:1000 \
    --tmpfs /tmp:rw,exec,nosuid,size=512m \
    --tmpfs /run:rw,noexec,nosuid,size=64m \
    --network "$NETWORK" \
    -v "$TEST_SECRET_DIR/test_api_key:/run/secrets/test_api_key:ro" \
    "$IMAGE" \
    bash -c 'echo $TEST_API_KEY' 2>&1)

rm -rf "$TEST_SECRET_DIR"

if [ "$SECRET_TEST" = "test-secret-value" ]; then
    pass "Secrets loaded from /run/secrets/ into environment variables"
else
    fail "Secret not loaded correctly" "Expected 'test-secret-value', got '$SECRET_TEST'"
fi

# Verify secrets are NOT visible via docker inspect (informational)
skip "Secrets not visible via docker inspect" "Cannot test from inside container (manual check)"

# ══════════════════════════════════════════════════════════════════════
section "Results"
echo ""
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  ${GREEN}Passed:  $PASS${NC}"
echo -e "  ${RED}Failed:  $FAIL${NC}"
echo -e "  ${YELLOW}Skipped: $SKIP${NC}"
echo -e "  ${BOLD}Total:   $TOTAL${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed! ✓${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}$FAIL test(s) failed. Review above for details.${NC}"
    exit 1
fi
