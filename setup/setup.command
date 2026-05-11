#!/usr/bin/env bash
set -euo pipefail

# Rakuten Claude Code Setup — macOS
# Authenticates via Okta PKCE, installs Git/VS Code/Claude Code extension,
# and writes ~/.claude/settings.json.

OKTA_ISSUER="https://rakuten.okta.com/oauth2/ausxr4nv1gcTtBswT357"
CLIENT_ID="0oa1hk5jgg1Oz3zDm358"
REDIRECT_URI="https://developer.ai.public.rakuten-it.com/callback"
SCOPES="openid email profile"
PAT_URL="https://developer-backend.ai.public.rakuten-it.com/projects/540fe463-79a3-4b91-894c-ec24c1012bd1/claude-code-aws-bedrock/config"

POLL=2
TIMEOUT=300

# ── colours & UI helpers ───────────────────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

clear_lines() {
  local n="${1:-1}"
  for (( i=0; i<n; i++ )); do
    printf '\033[1A\033[2K'
  done
}

print_header() {
  clear
  printf "${BOLD}${WHITE}"
  printf '╔══════════════════════════════════════════════════════╗\n'
  printf '║         Rakuten Claude Code Setup (macOS)            ║\n'
  printf '╚══════════════════════════════════════════════════════╝\n'
  printf "${RESET}\n"
}

step()        { printf "  ${BOLD}${CYAN}[${1}]${RESET} ${WHITE}${2}${RESET}\n"; }
step_done()   { printf "  ${BOLD}${GREEN}[${1}]${RESET} ${GREEN}${2}${RESET}\n"; }
step_active() { printf "  ${BOLD}${YELLOW}[${1}]${RESET} ${YELLOW}${2}${RESET}\n"; }
info()        { printf "      ${DIM}${1}${RESET}\n"; }
success()     { printf "\n  ${BOLD}${GREEN}✓  ${1}${RESET}\n"; }
warn()        { printf "\n  ${YELLOW}⚠  ${1}${RESET}\n" >&2; }
die()         { printf "\n  ${BOLD}${RED}✗  Error: ${1}${RESET}\n\n" >&2; exit 1; }

[[ "$OSTYPE" == darwin* ]] || die "This script requires macOS."
command -v openssl   &>/dev/null || die "openssl not found."
command -v curl      &>/dev/null || die "curl not found."
command -v osascript &>/dev/null || die "osascript not found."

# ── header ─────────────────────────────────────────────────────────────────────

print_header

printf "  This script will:\n"
step "1" "Sign you in with your Rakuten account"
step "2" "Install Git, VS Code, Claude Code extension, and plugins"
step "3" "Configure Claude Code automatically"
printf "\n"

# ── step 1: sign in ────────────────────────────────────────────────────────────

step_active "1" "Sign in with your Rakuten account"
info "Opening Safari — log in and complete MFA..."
printf "\n"

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

  frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  idx=$(( (elapsed / POLL) % 10 ))
  printf "\r      ${CYAN}${frames[$idx]}${RESET}  ${DIM}Waiting for sign-in... (${elapsed}s)${RESET}   "

  sleep "$POLL"
  elapsed=$(( elapsed + POLL ))
done
printf "\r\033[2K"

[[ -n "$CODE" ]] || die "Timed out after ${TIMEOUT}s. Did you complete the sign-in?"

info "Exchanging token..."

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

info "Fetching access key..."

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
  || die "PAT request failed (HTTP $HTTP_CODE): $PAT_BODY"

PAT=$(printf '%s' "$PAT_BODY" \
  | grep -o '"secret_key":"[^"]*"' \
  | sed 's/"secret_key":"//;s/"$//')
[[ -n "$PAT" ]] || die "No secret_key in response."

clear_lines 4
step_done "1" "Signed in successfully"

# ── step 2: install Git, VS Code, Claude Code extension ───────────────────────

step_active "2" "Install Git, VS Code, Claude Code extension, and plugins"
printf "\n"

# Git — already present on macOS via Xcode CLT; install CLT if absent
if ! command -v git &>/dev/null; then
  info "Installing Xcode Command Line Tools (includes Git)..."
  xcode-select --install 2>/dev/null || true
  # Wait for git to become available (CLT install is async/interactive)
  for i in $(seq 1 60); do
    command -v git &>/dev/null && break
    sleep 5
  done
  command -v git &>/dev/null || die "Git not found after CLT install. Please install manually and re-run."
  info "Git installed."
else
  info "Git already installed ($(git --version))."
fi

# VS Code — install via direct download if not present
if ! command -v code &>/dev/null && [[ ! -d "/Applications/Visual Studio Code.app" ]]; then
  info "Downloading VS Code..."
  VSCODE_DMG=/tmp/vscode-setup.dmg
  rm -f "$VSCODE_DMG"
  curl -fsSL --progress-bar \
    "https://update.code.visualstudio.com/latest/darwin-universal/stable" \
    -o "$VSCODE_DMG" \
    || die "Failed to download VS Code."
  printf "\n"

  info "Installing VS Code..."
  VSCODE_MOUNT=/tmp/vscode-mount
  rm -rf "$VSCODE_MOUNT"
  mkdir "$VSCODE_MOUNT"
  hdiutil attach "$VSCODE_DMG" -mountpoint "$VSCODE_MOUNT" -nobrowse -quiet \
    || die "Failed to mount VS Code DMG."
  cp -R "$VSCODE_MOUNT/Visual Studio Code.app" /Applications/ \
    || { hdiutil detach "$VSCODE_MOUNT" -quiet; die "Failed to copy VS Code."; }
  hdiutil detach "$VSCODE_MOUNT" -quiet
  rm -f "$VSCODE_DMG"
  rm -rf "$VSCODE_MOUNT"
  info "VS Code installed."
else
  info "VS Code already installed."
fi

# Ensure the `code` CLI is on PATH
CODE_CLI="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
if ! command -v code &>/dev/null && [[ -f "$CODE_CLI" ]]; then
  export PATH="$PATH:$(dirname "$CODE_CLI")"
fi

# Claude Code CLI
if ! command -v claude &>/dev/null; then
  info "Installing Claude Code CLI..."
  curl -fsSL https://claude.ai/install.sh | bash \
    || warn "Could not install Claude Code CLI automatically. Visit https://claude.ai/install for instructions."
  # Refresh PATH in case installer added to a new location
  export PATH="$HOME/.local/bin:$PATH"
else
  info "Claude Code CLI already installed ($(claude --version 2>/dev/null || true))."
fi

# Claude Code VS Code extension
if command -v code &>/dev/null; then
  if ! code --list-extensions 2>/dev/null | grep -qi "anthropic.claude-code"; then
    info "Installing Claude Code extension..."
    code --install-extension anthropic.claude-code --force \
      || warn "Could not install Claude Code extension automatically. Install it manually from the VS Code Marketplace."
  else
    info "Claude Code extension already installed."
  fi
else
  warn "VS Code CLI 'code' not on PATH — skipping extension install. Open VS Code and install 'Claude Code' from the Marketplace."
fi

# Claude plugins
if command -v claude &>/dev/null; then
  info "Adding claude-plugins-official registry..."
  claude plugin add anthropics/claude-plugins-official 2>/dev/null \
    || warn "Could not add plugin registry — run manually: claude plugin add anthropics/claude-plugins-official"

  info "Installing skill-creator plugin..."
  claude plugin install skill-creator@claude-plugins-official --scope user 2>/dev/null \
    || warn "Could not install skill-creator — run manually: claude plugin install skill-creator@claude-plugins-official --scope user"
else
  warn "'claude' CLI not found — skipping plugin install. After installing Claude Code, run:\n        claude plugin add anthropics/claude-plugins-official\n        claude plugin install skill-creator@claude-plugins-official --scope user"
fi

clear_lines 2
step_done "2" "Git, VS Code, Claude Code extension, and plugins ready"

# ── step 3: write ~/.claude/settings.json ─────────────────────────────────────

step_active "3" "Configuring Claude Code"
info "Writing ~/.claude/settings.json..."

SETTINGS_DIR="$HOME/.claude"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"

if [[ -f "$SETTINGS_FILE" ]] && command -v python3 &>/dev/null; then
  # Merge: preserve existing keys not in our list, overwrite the ones we own
  UPDATED=$(python3 - "$SETTINGS_FILE" <<PYEOF
import json, sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

env = data.setdefault("env", {})
env["ANTHROPIC_BEDROCK_BASE_URL"] = "https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1"
env["AWS_BEARER_TOKEN_BEDROCK"]   = """$PAT"""
env["CLAUDE_CODE_USE_BEDROCK"]    = "1"
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
  # Fresh write
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

clear_lines 2
step_done "3" "Claude Code configured"

# ── summary ────────────────────────────────────────────────────────────────────

printf "\n"
printf "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}\n"
printf "  ${BOLD}${GREEN}║                  Setup Complete! 🎉                  ║${RESET}\n"
printf "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "  ${WHITE}Next steps:${RESET}\n"
printf "  ${DIM}1. Open VS Code in your project folder${RESET}\n"
printf "  ${DIM}2. Press ${RESET}${BOLD}Cmd+Shift+P${RESET}${DIM} → \"Claude: Open Chat\" to start coding${RESET}\n"
printf "\n"
