#!/usr/bin/env bash
set -euo pipefail

# ── onec-mcp-universal setup ─────────────────────────────────────
# One-command setup: creates .env (with auto-detected 1C platform),
# builds Docker images, starts all containers, and registers the
# MCP server in Claude Code.
# Works on Linux, macOS, and Windows (Git Bash / WSL).

cd "$(dirname "$0")"

DEFAULT_PORT=8080
NAME="onec-universal"
ENV_PORT_KEY="GW_PORT"

# ── Helpers ──────────────────────────────────────────────────────
env_val() { grep "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2-; }

# Portable sed -i (macOS needs '' arg)
sed_inplace() {
  if [ "$OS" = "macos" ]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ── 1. Prerequisites ─────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || { echo "ERROR: Docker not found. Install: https://docs.docker.com/get-docker/"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: Docker Compose V2 not found."; exit 1; }

# ── 2. Detect OS ────────────────────────────────────────────────
OS="linux"
case "$(uname -s)" in
  Darwin*)                OS="macos"   ;;
  MINGW*|MSYS*|CYGWIN*)  OS="windows" ;;
esac

# macOS / Windows: use the provided override file
if [ "$OS" != "linux" ]; then
  if [ -f docker-compose.windows.yml ] && [ ! -f docker-compose.override.yml ]; then
    cp docker-compose.windows.yml docker-compose.override.yml
    echo "[+] Created docker-compose.override.yml for ${OS} (bridge network)"
  fi
fi

# ── 3. Create .env ──────────────────────────────────────────────
if [ ! -f .env ]; then
  cp .env.example .env

  # Auto-detect 1C platform path on Linux
  if [ "$OS" = "linux" ] && [ -d /opt/1cv8 ]; then
    PLATFORM_DIR=$(ls -1d /opt/1cv8/x86_64/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::' || true)
    if [ -n "${PLATFORM_DIR:-}" ]; then
      sed_inplace "s|^PLATFORM_PATH=.*|PLATFORM_PATH=${PLATFORM_DIR}|" .env
      echo "[+] Detected 1C platform: ${PLATFORM_DIR}"
    fi
  fi

  # Windows: adjust export host URL
  if [ "$OS" = "windows" ] || [ "$OS" = "macos" ]; then
    sed_inplace 's|^EXPORT_HOST_URL=.*|EXPORT_HOST_URL=http://host.docker.internal:8082|' .env
  fi

  echo "[+] Created .env from .env.example (port ${DEFAULT_PORT})"
else
  echo "[i] .env already exists, keeping it"
fi

PORT=$(env_val "$ENV_PORT_KEY" .env 2>/dev/null || true)
PORT=${PORT:-$DEFAULT_PORT}

# ── 4. Build & start ───────────────────────────────────────────
echo "[*] Building and starting containers (gateway + backends)..."
docker compose up -d --build --remove-orphans

# ── 5. Health check ─────────────────────────────────────────────
echo "[*] Waiting for health (backends need ~30-60s)..."
HEALTHY=0
for i in $(seq 1 90); do
  if curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1; then
    HEALTHY=1; break
  fi
  sleep 1
done

if [ "$HEALTHY" -eq 0 ]; then
  # Try container name variants
  for CN in onec-mcp-gw; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CN" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "healthy" ]; then HEALTHY=1; break; fi
  done
fi

if [ "$HEALTHY" -eq 1 ]; then
  echo "[+] Gateway is healthy on port ${PORT}"
else
  echo "[!] Gateway not healthy after 90s. Check: docker compose logs"
  exit 1
fi

# ── 6. Register in Claude Code ──────────────────────────────────
if command -v claude >/dev/null 2>&1; then
  claude mcp remove "$NAME" -s user 2>/dev/null || true
  claude mcp add --transport http -s user "$NAME" "http://localhost:${PORT}/mcp"
  echo "[+] Registered '${NAME}' in Claude Code (user scope)"
  echo ""
  echo "Done! Run 'claude' and use /mcp to verify."
else
  echo ""
  echo "[i] Claude Code CLI not found. Register manually:"
  echo "    claude mcp add --transport http -s user ${NAME} http://localhost:${PORT}/mcp"
fi

echo ""
echo "Dashboard: http://localhost:${PORT}/dashboard"
