#!/usr/bin/env bash
set -euo pipefail

# Rakuten Claude Code Setup — macOS (Summit)
# Authenticates via Okta PKCE, installs dev tools via curl,
# writes ~/.claude/settings.json, and installs rr-standards plugins.

OKTA_ISSUER="https://rakuten.okta.com/oauth2/ausxr4nv1gcTtBswT357"
CLIENT_ID="0oa1hk5jgg1Oz3zDm358"
REDIRECT_URI="https://developer.ai.public.rakuten-it.com/callback"
SCOPES="openid email profile"
PAT_URL="https://developer-backend.ai.public.rakuten-it.com/projects/540fe463-79a3-4b91-894c-ec24c1012bd1/claude-code-aws-bedrock/config"

POLL=2
TIMEOUT=300

# ── colours ───────────────────────────────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

step=0
total=11

DESKTOP="$HOME/Desktop"

# ── cert setup ────────────────────────────────────────────────────────────────
mkdir -p "$HOME/certs"
if [[ ! -f "$HOME/certs/rak-ca-bundle.pem" ]]; then
  run "Rakuten CA cert not found — downloading..." 2>/dev/null || true
  printf "  \033[2m→\033[0m  \033[2mRakuten CA cert not found — downloading...\033[0m\n"
  (
    if command -v wget &>/dev/null; then
      wget -q "http://pki.rakuten-it.com/pki/RootCA.zip" -O "$HOME/certs/RootCA.zip" 2>&1
    else
      curl -fsSL "http://pki.rakuten-it.com/pki/RootCA.zip" -o "$HOME/certs/RootCA.zip" 2>&1
    fi \
      && unzip -q -o "$HOME/certs/RootCA.zip" -d "$HOME/certs/" 2>&1 \
      && printf "  \033[0;32m✓\033[0m  \033[1;37mRakuten CA cert downloaded to ~/certs\033[0m\n" \
      || printf "  \033[0;33m⚠\033[0m  \033[0;33mCould not download Rakuten CA cert — continuing without it\033[0m\n"
    rm -f "$HOME/certs/RootCA.zip"
  ) || true
fi
export NODE_EXTRA_CA_CERTS="$HOME/certs/rak-ca-bundle.pem"

ok()      { printf "  ${GREEN}✓${RESET}  ${WHITE}${1}${RESET}\n"; }
run()     { printf "  ${CYAN}→${RESET}  ${DIM}${1}${RESET}\n"; }
warn()    { printf "  ${YELLOW}⚠${RESET}  ${YELLOW}${1}${RESET}\n" >&2; }
die()     { printf "\n  ${BOLD}${RED}✗  Error: ${1}${RESET}\n\n" >&2; exit 1; }
section() {
  step=$((step + 1))
  printf "\n  ${BOLD}${CYAN}[${step}/${total}] ${1}${RESET}\n"
}

# helper — unzip restaurant-booking from the DMG onto Desktop
install_restaurant_booking() {
  local zip=""
  while IFS= read -r vol; do
    vol="${vol%"${vol##*[![:space:]]}"}"
    if [[ -f "${vol}/assets/restaurant-booking.zip" ]]; then
      zip="${vol}/assets/restaurant-booking.zip"
      break
    fi
  done < <(mount | grep -i 'Rakuten Claude Code Setup' | sed 's|.* on \(/Volumes/[^)]*\) (.*|\1|')

  if [[ -z "$zip" ]]; then
    warn "restaurant-booking.zip not found on DMG — skipping"
    return
  fi

  run "Extracting restaurant-booking to Desktop..."
  rm -rf "${DESKTOP}/restaurant-booking"
  unzip -q -o "$zip" -d "${DESKTOP}" || true
  # zip contains a top-level folder; rename it to restaurant-booking if needed
  if [[ ! -d "${DESKTOP}/restaurant-booking" ]]; then
    local top
    top=$(unzip -Z1 "$zip" 2>/dev/null | grep '/' | head -1 | cut -d/ -f1) || true
    [[ -n "$top" && -d "${DESKTOP}/${top}" ]] && mv "${DESKTOP}/${top}" "${DESKTOP}/restaurant-booking" || true
  fi
  ok "restaurant-booking ready at ~/Desktop/restaurant-booking"

  local landscape="${DESKTOP}/restaurant-booking/.forge/products/restaurant-booking/competitive/initial-landscape.md"
  if [[ -f "$landscape" ]]; then
    cp "$landscape" "${DESKTOP}/initial-landscape.md"
    ok "initial-landscape.md copied to Desktop"
  else
    warn "initial-landscape.md not found in restaurant-booking"
  fi
}

# helper — create playground dir on Desktop
make_playground() {
  mkdir -p "${DESKTOP}/playground"
  ok "playground directory ready at ~/Desktop/playground"
}

[[ "$OSTYPE" == darwin* ]] || die "This script requires macOS."
command -v curl      &>/dev/null || die "curl not found."
command -v osascript &>/dev/null || die "osascript not found."

# ── header ─────────────────────────────────────────────────────────────────────

clear
printf "\n"
printf "  ${BOLD}${WHITE}Rakuten Claude Code Setup${RESET}  ${DIM}(macOS)${RESET}\n"
printf "  ${DIM}─────────────────────────────────────────${RESET}\n\n"

# ── already installed? ────────────────────────────────────────────────────────

PREV_INSTALL=$(osascript <<'APPLES'
tell application "System Events"
  activate
  set result to button returned of (display dialog "Did you install this setup before?" ¬
    buttons {"No — Fresh Install", "Yes — Update Project"} ¬
    default button "No — Fresh Install" ¬
    with title "Rakuten Claude Code Setup" ¬
    with icon note)
  return result
end tell
APPLES
)

if [[ "$PREV_INSTALL" == "Yes — Update Project" ]]; then
  printf "\n"
  ok "Re-run detected — refreshing project files only"
  install_restaurant_booking
  make_playground
  if [[ -d "${DESKTOP}/restaurant-booking" ]] && command -v node &>/dev/null; then
    run "Running npm install in restaurant-booking..."
    ( cd "${DESKTOP}/restaurant-booking" && npm install 2>&1 ) || true
    ok "npm install done"

    run "Starting dev server..."
    ( cd "${DESKTOP}/restaurant-booking" && npm run dev & )
    sleep 3 && open "http://localhost:3000" || true
    ok "Dev server started at http://localhost:3000"
  fi
  while IFS= read -r vol; do
    vol="${vol%"${vol##*[![:space:]]}"}"
    hdiutil detach "$vol" -quiet 2>/dev/null || true
  done < <(mount | grep -i 'Rakuten Claude Code Setup' | sed 's|.* on \(/Volumes/[^)]*\) (.*|\1|')
  printf "\n"
  printf "  ${DIM}─────────────────────────────────────────${RESET}\n"
  ok "Done"
  printf "\n"
  exit 0
fi

# ── step 1: git ────────────────────────────────────────────────────────────────

section "Git"

if command -v git &>/dev/null; then
  ok "Git already installed ($(git --version | awk '{print $3}'))"
else
  run "Installing Git via Xcode Command Line Tools..."
  xcode-select --install 2>/dev/null || true
  # Wait up to 120s for git to appear
  for i in $(seq 1 24); do
    command -v git &>/dev/null && break
    sleep 5
  done
  command -v git &>/dev/null && ok "Git installed ($(git --version | awk '{print $3}'))" \
    || warn "Git not found after install — you may need to restart Terminal"
fi

# ── step 2: node.js ────────────────────────────────────────────────────────────

section "Node.js"

if command -v node &>/dev/null; then
  ok "Node.js already installed ($(node --version))"
else
  run "Downloading Node.js LTS..."
  NODE_PKG=/tmp/node-lts.pkg
  # Get latest LTS version from tab-separated index (no python needed)
  NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/index.tab 2>/dev/null \
    | awk -F'\t' 'NR>1 && $10!="false" {print $1; exit}')
  curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}.pkg" -o "$NODE_PKG"
  run "Installing Node.js ${NODE_VERSION}..."
  sudo installer -pkg "$NODE_PKG" -target / > /dev/null
  rm -f "$NODE_PKG"
  export PATH="/usr/local/bin:$PATH"
  command -v node &>/dev/null && ok "Node.js installed ($(node --version))" \
    || warn "Node.js not found on PATH — you may need to restart Terminal"
fi

# ── step 3: claude code cli ────────────────────────────────────────────────────

section "Claude Code CLI"

if command -v claude &>/dev/null; then
  ok "Claude Code CLI already installed ($(claude --version 2>/dev/null || echo 'version unknown'))"
else
  run "Installing Claude Code CLI..."
  curl -fsSL https://claude.ai/install.sh | bash \
    || warn "Could not install Claude Code CLI automatically. Visit https://claude.ai/install"
  export PATH="$HOME/.local/bin:$PATH"
  command -v claude &>/dev/null && ok "Claude Code CLI installed" \
    || warn "Claude Code CLI not found on PATH after install — restart Terminal after setup"
fi

# ── step 4: vs code ────────────────────────────────────────────────────────────

section "Visual Studio Code"

if command -v code &>/dev/null \
  || [[ -d "/Applications/Visual Studio Code.app" ]] \
  || [[ -d "$HOME/Applications/Visual Studio Code.app" ]]; then
  ok "VS Code already installed"
  # Ensure code CLI is on PATH even if VS Code was pre-installed
  if ! command -v code &>/dev/null; then
    VSCODE_APP="/Applications/Visual Studio Code.app"
    [[ -d "$HOME/Applications/Visual Studio Code.app" ]] && VSCODE_APP="$HOME/Applications/Visual Studio Code.app"
    mkdir -p "$HOME/.local/bin"
    ln -sf "${VSCODE_APP}/Contents/Resources/app/bin/code" "$HOME/.local/bin/code" 2>/dev/null || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
else
  run "Downloading Visual Studio Code..."
  VSCODE_DMG=/tmp/VSCode-darwin.dmg
  curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=darwin-universal-dmg" \
    -o "$VSCODE_DMG"
  run "Installing Visual Studio Code..."
  VSCODE_MOUNT=$(hdiutil attach "$VSCODE_DMG" -nobrowse -quiet | grep '/Volumes/' | sed 's|.*\(/Volumes/.*\)|\1|') || true
  if [[ -d "${VSCODE_MOUNT}/Visual Studio Code.app" ]]; then
    ADMIN_PASS=$(osascript -e 'display dialog "Enter your Mac password to install Visual Studio Code to /Applications:" with title "Install Visual Studio Code" default answer "" with hidden answer giving up after 120' -e 'text returned of result' 2>/dev/null) || true
    if [[ -n "$ADMIN_PASS" ]]; then
      echo "$ADMIN_PASS" | sudo -S cp -R "${VSCODE_MOUNT}/Visual Studio Code.app" /Applications/ 2>/dev/null || true
    fi
    # fallback to ~/Applications if /Applications install failed
    if [[ ! -d "/Applications/Visual Studio Code.app" ]]; then
      mkdir -p "$HOME/Applications"
      cp -R "${VSCODE_MOUNT}/Visual Studio Code.app" "$HOME/Applications/" 2>/dev/null || true
    fi
  else
    warn "VS Code app not found in DMG — skipping"
  fi
  hdiutil detach "$VSCODE_MOUNT" -quiet 2>/dev/null || true
  rm -f "$VSCODE_DMG"
  # Symlink code CLI
  VSCODE_APP="/Applications/Visual Studio Code.app"
  [[ ! -d "$VSCODE_APP" ]] && VSCODE_APP="$HOME/Applications/Visual Studio Code.app"
  mkdir -p "$HOME/.local/bin"
  ln -sf "${VSCODE_APP}/Contents/Resources/app/bin/code" "$HOME/.local/bin/code" 2>/dev/null || true
  export PATH="$HOME/.local/bin:$PATH"
  ok "VS Code installed"
fi

# ── step 5: claude code vs code extension ─────────────────────────────────────

section "Claude Code VS Code extension"

if command -v code &>/dev/null; then
  if code --list-extensions 2>/dev/null | grep -qi "anthropic.claude-code"; then
    ok "Claude Code extension already installed"
  else
    run "Installing Claude Code extension..."
    code --install-extension anthropic.claude-code \
      && ok "Claude Code extension installed" \
      || warn "Could not install extension — install manually from VS Code marketplace"
  fi
else
  warn "VS Code CLI not on PATH — skipping extension install"
fi

# ── step 6: okta sign-in ───────────────────────────────────────────────────────

section "Rakuten OKTA sign-in"

run "Opening browser for Rakuten OKTA sign-in..."

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

VERIFIER=$(openssl rand -base64 48 | tr -d '=+/\n' | tr '+/' '-_' | cut -c1-64)
CHALLENGE=$(printf '%s' "$VERIFIER" \
  | openssl dgst -binary -sha256 \
  | openssl base64 \
  | tr -d '=\n' \
  | tr '+/' '-_')
STATE=$(openssl rand -hex 16)

AUTH_URL="${OKTA_ISSUER}/v1/authorize\
?response_type=code\
&client_id=${CLIENT_ID}\
&redirect_uri=$(urlencode "$REDIRECT_URI")\
&scope=$(urlencode "$SCOPES")\
&state=${STATE}\
&code_challenge=${CHALLENGE}\
&code_challenge_method=S256"

open -a Safari
for i in $(seq 1 30); do
  osascript -e 'tell application "Safari" to get version' &>/dev/null && break
  sleep 1
done

osascript <<APPLES
tell application "Safari"
  activate
  if (count of windows) = 0 then
    make new document with properties {URL:"${AUTH_URL}"}
  else
    set URL of current tab of front window to "${AUTH_URL}"
  end if
end tell
APPLES

elapsed=0
CODE=""
while (( elapsed < TIMEOUT )); do
  TAB_URL=$(osascript 2>/dev/null <<'APPLES' || true
tell application "Safari"
  if (count of windows) > 0 then
    return URL of current tab of front window
  end if
  return ""
end tell
APPLES
  )

  if [[ "$TAB_URL" == *"developer.ai.public.rakuten-it.com/callback"* ]] \
  && [[ "$TAB_URL" == *"code="* ]]; then
    CODE=$(printf '%s' "$TAB_URL" | grep -o 'code=[^&]*' | head -1 | cut -d= -f2)
    GOT_STATE=$(printf '%s' "$TAB_URL" | grep -o 'state=[^&]*' | head -1 | cut -d= -f2)
    [[ "$GOT_STATE" == "$STATE" ]] || die "State mismatch — possible CSRF. Aborting."
    osascript 2>/dev/null <<'APPLES' || true
tell application "Safari"
  close front window
end tell
APPLES
    break
  fi

  printf "\r  ${DIM}Waiting for sign-in... (${elapsed}s)${RESET}   "
  sleep "$POLL"
  elapsed=$(( elapsed + POLL ))
done
printf "\r\033[2K"

[[ -n "$CODE" ]] || die "Timed out after ${TIMEOUT}s. Did you complete sign-in?"

run "Exchanging token..."

TOKEN_RESPONSE=$(curl -fsS \
  -X POST "${OKTA_ISSUER}/v1/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}" \
  --data-urlencode "code=${CODE}" \
  --data-urlencode "code_verifier=${VERIFIER}" \
) || die "Token exchange failed."

ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" \
  | grep -o '"access_token":"[^"]*"' \
  | sed 's/"access_token":"//;s/"$//')
[[ -n "$ACCESS_TOKEN" ]] || die "No access_token in response."

run "Fetching Rakuten AI access key..."

PAT_RESPONSE=$(curl -sS \
  -X POST "$PAT_URL" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json, text/plain, */*" \
  -H "Origin: https://developer.ai.public.rakuten-it.com" \
  -H "Referer: https://developer.ai.public.rakuten-it.com/" \
  --write-out "\nHTTP_STATUS:%{http_code}" 2>&1)

HTTP_CODE=$(printf '%s' "$PAT_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
PAT_BODY=$(printf '%s' "$PAT_RESPONSE" | sed '/HTTP_STATUS:/d')
[[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]] \
  || die "Access key request failed (HTTP $HTTP_CODE): $PAT_BODY"

PAT=$(printf '%s' "$PAT_BODY" \
  | grep -o '"secret_key":"[^"]*"' \
  | sed 's/"secret_key":"//;s/"$//')
[[ -n "$PAT" ]] || die "No secret_key in response."

USER_EMAIL=$(curl -sS "${OKTA_ISSUER}/v1/userinfo" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  | grep -o '"email":"[^"]*"' \
  | sed 's/"email":"//;s/"$//')

ok "Signed in${USER_EMAIL:+ as ${USER_EMAIL}}"

# ── step 7: write ~/.claude/settings.json ─────────────────────────────────────

section "Rakuten AI Gateway config"

run "Writing ~/.claude/settings.json..."

SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"

if [[ -f "$SETTINGS_FILE" ]] && command -v python3 &>/dev/null; then
  UPDATED=$(python3 - "$SETTINGS_FILE" <<PYEOF
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

env = data.setdefault("env", {})
env["ANTHROPIC_BEDROCK_BASE_URL"]    = "https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1"
env["AWS_BEARER_TOKEN_BEDROCK"]      = """$PAT"""
env["CLAUDE_CODE_USE_BEDROCK"]       = "1"
env["CLAUDE_CODE_SKIP_BEDROCK_AUTH"] = "1"
env["CLAUDE_CODE_ENABLE_TELEMETRY"]  = "1"
env["OTEL_METRICS_EXPORTER"]         = "otlp"
env["OTEL_LOGS_EXPORTER"]            = "otlp"
env["OTEL_EXPORTER_OTLP_PROTOCOL"]   = "http/protobuf"
env["OTEL_EXPORTER_OTLP_ENDPOINT"]   = "https://api.ai.public.rakuten-it.com/otel"
env["OTEL_EXPORTER_OTLP_HEADERS"]    = "Authorization=$PAT"

print(json.dumps(data, indent=2))
PYEOF
  )
  printf '%s\n' "$UPDATED" > "$SETTINGS_FILE"
else
  cat > "$SETTINGS_FILE" <<JSON
{
  "env": {
    "ANTHROPIC_BEDROCK_BASE_URL": "https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1",
    "AWS_BEARER_TOKEN_BEDROCK": "$PAT",
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "1",
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "https://api.ai.public.rakuten-it.com/otel",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=$PAT"
  }
}
JSON
fi

ok "Claude Code configured → Rakuten AI gateway"

# ── step 8: rr-standards marketplace ─────────────────────────────────────────

section "rr-standards marketplace"

# Find rr-standards.zip — scan all mounted Rakuten Claude Code Setup volumes
RR_ZIP=""
while IFS= read -r vol; do
  vol="${vol%"${vol##*[![:space:]]}"}"  # trim trailing whitespace
  if [[ -f "${vol}/assets/rr-standards.zip" ]]; then
    RR_ZIP="${vol}/assets/rr-standards.zip"
    break
  fi
done < <(mount | grep -i 'Rakuten Claude Code Setup' | sed 's|.* on \(/Volumes/[^)]*\) (.*|\1|')

if command -v claude &>/dev/null; then
  run "Removing any existing rr-standards marketplace entry..."
  claude plugin marketplace remove rr-standards 2>&1 || true

  if [[ -n "$RR_ZIP" ]]; then
    run "Extracting rr-standards to Desktop..."
    RR_DEST="${DESKTOP}/rr-standards"
    RR_TMP=/tmp/rr-standards-extract
    rm -rf "$RR_TMP" && mkdir -p "$RR_TMP"
    unzip -q -o "$RR_ZIP" -d "$RR_TMP" || true
    rm -rf "$RR_DEST"
    # move whatever top-level folder was extracted
    rr_top=$(ls "$RR_TMP" | grep -v __MACOSX | head -1) || true
    if [[ -n "$rr_top" ]]; then
      mv "${RR_TMP}/${rr_top}" "$RR_DEST"
    fi
    rm -rf "$RR_TMP"
    ok "rr-standards extracted to ~/Desktop/rr-standards"

    run "Adding rr-standards marketplace from ~/Desktop/rr-standards..."
    claude plugin marketplace add "$RR_DEST" 2>&1 \
      && ok "rr-standards marketplace added" \
      || warn "Could not add rr-standards marketplace"
  else
    warn "rr-standards.zip not found on DMG — cannot add marketplace"
  fi
else
  warn "claude CLI not on PATH — skipping marketplace step"
fi

# ── step 9: install plugins ───────────────────────────────────────────────────

section "Installing forge plugins"

if command -v claude &>/dev/null; then
  for plugin in forge forge-product-management forge-skill-creator; do
    run "Removing any existing ${plugin}..."
    claude plugin remove "$plugin" 2>&1 || true
    run "Installing ${plugin}..."
    if claude plugin install "$plugin" 2>&1; then
      ok "${plugin} installed"
    else
      warn "Could not install ${plugin}"
    fi
  done
else
  warn "claude CLI not on PATH — skipping plugin install"
fi

# ── step 10: mcp integrations ────────────────────────────────────────────────

section "MCP integrations"

if command -v claude &>/dev/null; then
  run "Adding Monday.com MCP..."
  claude mcp add --transport sse mondaycom https://mcp.monday.com/sse --scope user 2>&1 \
    && ok "Monday.com MCP added" || warn "Monday.com MCP may already be configured"

  run "Adding Playwright MCP..."
  claude mcp add playwright -- npx @executeautomation/playwright-mcp-server 2>&1 \
    && ok "Playwright MCP added" || warn "Playwright MCP may already be configured"

  run "Adding BrowserStack MCP..."
  claude mcp add --transport http browserstack-remote https://mcp.browserstack.com/mcp 2>&1 \
    && ok "BrowserStack MCP added" || warn "BrowserStack MCP may already be configured"

  run "Adding Figma MCP..."
  claude mcp add --transport http --scope user figma https://mcp.figma.com/mcp 2>&1 \
    && ok "Figma MCP added" || warn "Figma MCP may already be configured"
else
  warn "claude CLI not on PATH — skipping MCP integrations"
fi

# ── step 11: restaurant-booking project ──────────────────────────────────────

section "restaurant-booking project"

install_restaurant_booking
make_playground

# npm install inside restaurant-booking (non-blocking)
if [[ -d "${DESKTOP}/restaurant-booking" ]] && command -v node &>/dev/null; then
  run "Running npm install in restaurant-booking..."
  ( cd "${DESKTOP}/restaurant-booking" && npm install 2>&1 ) || true
  ok "npm install done"

  run "Starting dev server..."
  ( cd "${DESKTOP}/restaurant-booking" && npm run dev & )
  sleep 3 && open "http://localhost:3000" || true
  ok "Dev server started at http://localhost:3000"
fi

# Eject all mounted Rakuten Claude Code Setup volumes
while IFS= read -r vol; do
  vol="${vol%"${vol##*[![:space:]]}"}"
  hdiutil detach "$vol" -quiet 2>/dev/null || true
done < <(mount | grep -i 'Rakuten Claude Code Setup' | sed 's|.* on \(/Volumes/[^)]*\) (.*|\1|')

# ── done ──────────────────────────────────────────────────────────────────────

printf "\n"
printf "  ${DIM}─────────────────────────────────────────${RESET}\n"
ok "Setup complete"
printf "\n"
printf "  ${DIM}Next steps:${RESET}\n"
printf "  ${DIM}1. Open your project folder and run${RESET} ${BOLD}claude${RESET}${DIM} to start coding${RESET}\n"
printf "  ${DIM}2. Or open VS Code and use the Claude Code extension${RESET}\n"
printf "\n"
printf "  ${DIM}Press any key to close...${RESET}\n"
read -n 1 -s
