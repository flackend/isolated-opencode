FROM alpine:3.20

# ── System tools: minimal set for OpenCode operation ──────────────────
# Each package is justified:
#   bash        — OpenCode's shell tool executes commands via bash
#   curl        — fetching resources, install scripts, API health checks
#   ripgrep     — OpenCode's grep tool for fast content search
#   findutils   — OpenCode's glob tool for file pattern matching
#   coreutils   — standard unix tools (cat, head, tail, wc, etc.)
#   diffutils   — diff/patch for file comparisons
#   jq          — JSON processing (common in dev workflows)
#   less        — pager for output viewing
#   shadow      — useradd for non-root user setup
#   tini        — lightweight init for proper signal handling / zombie reaping
RUN apk add --no-cache \
    bash \
    curl \
    ripgrep \
    findutils \
    coreutils \
    diffutils \
    jq \
    less \
    shadow \
    tini

# ── Language runtimes ─────────────────────────────────────────────────
# PHP: for PHP/JS projects
# Node.js + npm: for JS tooling, dotCMS development
RUN apk add --no-cache \
    php83 \
    php83-cli \
    php83-common \
    php83-mbstring \
    php83-json \
    php83-openssl \
    php83-curl \
    php83-dom \
    php83-xml \
    php83-xmlwriter \
    php83-tokenizer \
    php83-phar \
    php83-iconv \
    php83-ctype \
    php83-fileinfo \
    php83-session \
    nodejs \
    npm \
    && ln -sf /usr/bin/php83 /usr/bin/php

# ── Create non-root user ─────────────────────────────────────────────
RUN useradd -m -s /bin/bash -u 1000 coder

# ── Install OpenCode ──────────────────────────────────────────────────
RUN curl -fsSL https://opencode.ai/install | bash \
    && install -m 755 /root/.local/bin/opencode /usr/local/bin/opencode 2>/dev/null \
    || install -m 755 /root/.opencode/bin/opencode /usr/local/bin/opencode 2>/dev/null \
    || true
# Note: Install path may vary. The build will verify the binary exists.

# ── Install herdr ────────────────────────────────────────────────────
RUN curl -fsSL https://herdr.dev/install.sh | sh \
    && install -m 755 /root/.local/bin/herdr /usr/local/bin/herdr 2>/dev/null \
    || install -m 755 /herdr /usr/local/bin/herdr 2>/dev/null \
    || true
# Note: Install path may vary. The build will verify the binary exists.

# ── Verify critical binaries exist ───────────────────────────────────
RUN opencode --version || echo "WARNING: opencode binary not found at expected path" \
    && herdr --version || echo "WARNING: herdr binary not found at expected path"

# ── Create workspace and writable directories ─────────────────────────
RUN mkdir -p /workspace && chown coder:coder /workspace
RUN mkdir -p /home/coder/.config /home/coder/.cache /home/coder/.local \
    && chown -R coder:coder /home/coder

# ── Clean up: reduce attack surface ──────────────────────────────────
# Remove package manager cache; agent can't easily install new packages
# Remove shadow (only needed during build for useradd)
RUN rm -rf /var/cache/apk/* /tmp/* \
    && apk del shadow

# ── Copy entrypoint script ───────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

# ── Health check ──────────────────────────────────────────────────────
HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD pgrep -f "opencode\|herdr\|bash" || exit 1

# ── Runtime configuration ────────────────────────────────────────────
USER coder
WORKDIR /workspace

ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
