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
total=9

ok()      { printf "  ${GREEN}✓${RESET}  ${WHITE}${1}${RESET}\n"; }
run()     { printf "  ${CYAN}→${RESET}  ${DIM}${1}${RESET}\n"; }
warn()    { printf "  ${YELLOW}⚠${RESET}  ${YELLOW}${1}${RESET}\n" >&2; }
die()     { printf "\n  ${BOLD}${RED}✗  Error: ${1}${RESET}\n\n" >&2; exit 1; }
section() {
  step=$((step + 1))
  printf "\n  ${BOLD}${CYAN}[${step}/${total}] ${1}${RESET}\n"
}

[[ "$OSTYPE" == darwin* ]] || die "This script requires macOS."
command -v curl      &>/dev/null || die "curl not found."
command -v osascript &>/dev/null || die "osascript not found."

# ── header ─────────────────────────────────────────────────────────────────────

clear
printf "\n"
printf "  ${BOLD}${WHITE}Rakuten Claude Code Setup${RESET}  ${DIM}(macOS)${RESET}\n"
printf "  ${DIM}─────────────────────────────────────────${RESET}\n\n"

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
  # Get latest LTS version number
  NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/index.json \
    | python3 -c "import json,sys; lts=[r for r in json.load(sys.stdin) if r['lts']]; print(lts[0]['version'])")
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

if command -v code &>/dev/null || [[ -d "/Applications/Visual Studio Code.app" ]]; then
  ok "VS Code already installed"
else
  run "Downloading Visual Studio Code..."
  VSCODE_ZIP=/tmp/VSCode-darwin.zip
  curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=darwin-universal" \
    -o "$VSCODE_ZIP"
  run "Installing Visual Studio Code..."
  unzip -q "$VSCODE_ZIP" -d /tmp/VSCode-extract
  mv "/tmp/VSCode-extract/Visual Studio Code.app" /Applications/ 2>/dev/null \
    || sudo mv "/tmp/VSCode-extract/Visual Studio Code.app" /Applications/
  rm -rf "$VSCODE_ZIP" /tmp/VSCode-extract
  # Symlink code CLI
  sudo ln -sf "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
    /usr/local/bin/code 2>/dev/null || true
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

# ── step 8: install rr-standards plugins ──────────────────────────────────────

section "rr-standards plugins"

run "Extracting rr-standards..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Eject any stale "Rakuten Claude Code Setup" volumes that aren't the one we're running from
while IFS= read -r vol; do
  [[ "$vol" == "$SCRIPT_DIR" ]] && continue
  hdiutil detach "$vol" -quiet 2>/dev/null || true
done < <(mount | grep -i 'Rakuten Claude Code Setup' | sed 's|.* on \(/Volumes/[^(]*\) (.*|\1|' | sed 's/ *$//')

# The script lives on the DMG volume — assets/ is always next to it
RR_ZIP=""
if [[ -f "${SCRIPT_DIR}/assets/rr-standards.zip" ]]; then
  RR_ZIP="${SCRIPT_DIR}/assets/rr-standards.zip"
fi

if [[ -z "$RR_ZIP" ]]; then
  warn "rr-standards.zip not found — skipping plugin install"
else
  RR_DEST="$HOME/rr-standards"
  RR_TMP=/tmp/rr-standards-extract
  rm -rf "$RR_TMP" && mkdir -p "$RR_TMP"
  unzip -q "$RR_ZIP" -d "$RR_TMP"

  # rr-standards-main is the top-level folder in the zip
  SRC="${RR_TMP}/rr-standards-main"

  rm -rf "$RR_DEST"
  cp -R "$SRC" "$RR_DEST"
  rm -rf "$RR_TMP"

  ok "rr-standards extracted to ~/rr-standards"

  if command -v claude &>/dev/null; then
    for plugin in forge forge-skill-creator forge-product-management; do
      PLUGIN_PATH="$RR_DEST/plugins/${plugin}"
      if [[ -d "$PLUGIN_PATH" ]]; then
        run "Installing ${plugin}..."
        claude plugin install "$PLUGIN_PATH" --force 2>&1 \
          && ok "${plugin} installed" \
          || warn "Could not install ${plugin}"
      else
        warn "Plugin directory not found: ${PLUGIN_PATH}"
      fi
    done
  else
    warn "claude CLI not on PATH — skipping plugin install (run after restarting Terminal)"
  fi
fi

# ── step 9: marketplace ────────────────────────────────────────────────────────

section "rr-standards marketplace"

if command -v claude &>/dev/null; then
  run "Removing any existing rr-standards marketplace entry..."
  claude plugin marketplace remove rr-standards 2>&1 || true

  run "Adding rr-standards from marketplace..."
  claude plugin marketplace add rewards-guilds/rr-standards 2>&1 \
    && ok "rr-standards marketplace added" \
    || warn "rr-standards may already be added"
else
  warn "claude CLI not on PATH — skipping marketplace step"
fi

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
