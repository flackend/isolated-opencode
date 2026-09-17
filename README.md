# OpenCode Sandbox

A hardened Docker container for running [OpenCode](https://opencode.ai) and [herdr](https://herdr.dev) in isolation. The agent has internet access for API calls and package management but **cannot reach the host, other containers, or LAN devices**.

## Security Features

| Layer | Protection |
|:---|:---|
| **User** | Non-root (`coder`, UID 1000) |
| **Capabilities** | All dropped (`--cap-drop ALL`) |
| **Privileges** | `no-new-privileges` enforced |
| **Filesystem** | Read-only rootfs; writable only at `/tmp` (tmpfs, noexec), `/home/coder` (volume), `/workspace` (bind mount) |
| **Network** | Isolated bridge (`enable_icc=false`), no host/LAN access |
| **Resources** | 4 GB memory, 2 CPUs, 256 PID limit |
| **Secrets** | Files at `/run/secrets/` (read-only), not env vars in `docker inspect` |
| **Excluded tools** | No `docker`, `sudo`, `su`, `nc`, `socat`, `ssh`, `iptables`, `git` |

## Quick Start

### 1. Build the image

```bash
docker build -t opencode-sandbox .
```

### 2. Set up API keys

Create secret files (one key per file, filename becomes the env var name):

```bash
mkdir -p ~/.config/opencode/secrets/

# Add your API keys — one per file
echo "sk-ant-..." > ~/.config/opencode/secrets/anthropic_api_key
echo "sk-..."     > ~/.config/opencode/secrets/openai_api_key

# Lock down permissions
chmod 600 ~/.config/opencode/secrets/*
```

The entrypoint script converts filenames to uppercase env vars:
- `anthropic_api_key` → `ANTHROPIC_API_KEY`
- `openai_api_key` → `OPENAI_API_KEY`

### 3. Launch for a project

```bash
./run.sh /path/to/your/project
```

This mounts your project at `/workspace` inside the container. No files are added to the project repo.

### 4. Use with different projects

```bash
./run.sh ~/code/my-php-project
./run.sh ~/code/my-dotcms-site
./run.sh ../some-other-repo
```

Each project gets its own persistent volume for OpenCode/herdr state (`opencode-home-<project-name>`).

## Interacting with a Running Container

```bash
# Attach to the container (Ctrl+P, Ctrl+Q to detach without stopping)
docker attach opencode-<project-name>

# Or run a command in the container
docker exec -it opencode-<project-name> bash
```

## Running Tests

Verify the container is correctly hardened:

```bash
./tests.sh
```

This runs ~20 automated checks and reports PASS/FAIL for each.

## What's Installed

### System Tools
`bash`, `curl`, `ripgrep`, `findutils`, `coreutils`, `diffutils`, `jq`, `less`

### Language Runtimes
- **PHP 8.3** — with extensions: cli, mbstring, json, openssl, curl, dom, xml, tokenizer, phar
- **Node.js + npm**

### AI Tools
- **OpenCode** — terminal-based AI coding agent
- **herdr** — terminal multiplexer / session manager for AI agents

### What's NOT Installed (by design)
`git`, `docker`, `sudo`, `su`, `nc`, `ncat`, `socat`, `nmap`, `ssh`, `sshd`, `iptables`, `ip`, `gcc`, `make`

> **Note on git:** Git is intentionally excluded. Manage version control outside the container. This means OpenCode's `/undo` command and change snapshots will not work inside the container.

## File Structure

```
opencode/
├── Dockerfile          # Container image definition
├── entrypoint.sh       # Loads secrets from /run/secrets/ → env vars
├── run.sh              # Launcher script (takes project path)
├── tests.sh            # Automated verification suite
├── .dockerignore       # Build context exclusions
└── README.md           # This file
```

## Customizing

### Adding more language runtimes

Edit the Dockerfile and add packages to the language runtimes section:

```dockerfile
# Example: add Python
RUN apk add --no-cache python3 py3-pip
```

Rebuild: `docker build -t opencode-sandbox .`

### Changing resource limits

Edit `run.sh` and modify the `--memory` and `--cpus` flags.

### Adding OpenCode config per project

Create an `opencode.json` in your project root (OpenCode reads this automatically):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "bash": {
      "*": "ask",
      "npm *": "allow",
      "node *": "allow",
      "php *": "allow"
    }
  }
}
```
