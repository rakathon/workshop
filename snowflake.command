#!/bin/bash

# Snowflake MCP Setup for Rakuten Rewards CoWork

set -e

echo "=== Snowflake MCP Setup for Cowork ==="
echo ""

read -p "Enter your Rakuten Ebates email (e.g. Tomas Jerry → tjerry@ebates.com): " EBATES_EMAIL
echo ""

# --- Step 1: Check / install uv ---

echo "==> [1/4] Checking for uvx..."

UVX_PATH=""
if command -v uvx &>/dev/null; then
  UVX_PATH=$(command -v uvx)
elif [ -f "$HOME/.local/bin/uvx" ]; then
  UVX_PATH="$HOME/.local/bin/uvx"
fi

if [ -z "$UVX_PATH" ]; then
  echo "    uvx not found — installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  if [ -f "$HOME/.local/bin/uvx" ]; then
    UVX_PATH="$HOME/.local/bin/uvx"
  else
    echo "ERROR: uvx still not found after install. Restart Terminal and re-run this script."
    exit 1
  fi
fi

echo "    uvx: $UVX_PATH"

# --- Step 2: Create ~/.snowflake/connections.toml ---

echo ""
echo "==> [2/4] Writing ~/.snowflake/connections.toml..."

mkdir -p "$HOME/.snowflake"
cat > "$HOME/.snowflake/connections.toml" << EOF
[default]
account = "rakutenusa-ebates"
user = "$EBATES_EMAIL"
authenticator = "externalbrowser"
EOF

echo "    Done."

# --- Step 3: Create ~/snowflake-mcp/tools_config.yaml ---

echo ""
echo "==> [3/4] Writing ~/snowflake-mcp/tools_config.yaml..."

mkdir -p "$HOME/snowflake-mcp"
cat > "$HOME/snowflake-mcp/tools_config.yaml" << 'EOF'
agent_services: []
search_services: []
analyst_services: []

other_services:
  object_manager: true
  query_manager: true
  semantic_manager: false

sql_statement_permissions:
  - Select: true
  - Describe: true
  - Use: true
  - Create: false
  - Drop: false
  - Insert: false
  - Update: false
  - Delete: false
  - Unknown: false
EOF

echo "    Done."

# --- Done ---

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Next steps:"
echo "  1. Fully quit and relaunch Cowork (Rakuten Rewards CoWork)"
echo "  2. A browser window will open — log in with your Okta credentials"
echo "  3. Test in Cowork: SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE();"
echo ""
echo "Troubleshooting logs (if needed):"
echo "  tail -50 ~/Library/Logs/Claude-3p/mcp-server-snowflake.log"
