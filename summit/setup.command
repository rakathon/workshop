#!/usr/bin/env bash
set -euo pipefail

# Rakuten Claude Code Setup — macOS (Summit)
# Authenticates via Okta PKCE, installs Claude Code CLI,
# writes ~/.claude/settings.json, and installs rr-standards plugin.

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

ok()   { printf "  ${GREEN}✓${RESET}  ${WHITE}${1}${RESET}\n"; }
run()  { printf "  ${CYAN}→${RESET}  ${DIM}${1}${RESET}\n"; }
warn() { printf "  ${YELLOW}⚠${RESET}  ${YELLOW}${1}${RESET}\n" >&2; }
die()  { printf "\n  ${BOLD}${RED}✗  Error: ${1}${RESET}\n\n" >&2; exit 1; }

[[ "$OSTYPE" == darwin* ]] || die "This script requires macOS."
command -v openssl   &>/dev/null || die "openssl not found."
command -v curl      &>/dev/null || die "curl not found."
command -v osascript &>/dev/null || die "osascript not found."

# ── header ─────────────────────────────────────────────────────────────────────

clear
printf "\n"
printf "  ${BOLD}${WHITE}Rakuten Claude Code Setup${RESET}  ${DIM}(macOS)${RESET}\n"
printf "  ${DIM}─────────────────────────────────────────${RESET}\n\n"

# ── step 1: okta sign-in ───────────────────────────────────────────────────────

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

# ── step 2: install Claude Code CLI ───────────────────────────────────────────

run "Installing Claude Code CLI..."

if ! command -v claude &>/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash \
    || warn "Could not install Claude Code CLI automatically. Visit https://claude.ai/install"
  export PATH="$HOME/.local/bin:$PATH"
  command -v claude &>/dev/null && ok "Claude Code CLI installed" \
    || warn "Claude Code CLI not found on PATH after install — you may need to restart your terminal"
else
  ok "Claude Code CLI already installed ($(claude --version 2>/dev/null || echo 'version unknown'))"
fi

# ── step 3: write ~/.claude/settings.json ─────────────────────────────────────

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

# ── step 4: install rr-standards plugin ───────────────────────────────────────

run "Installing rr-standards plugin..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locate the volume (running from DMG) or fall back to local assets/
PLUGIN_VOLUME=""
while IFS= read -r vol; do
  [[ -n "$vol" ]] && PLUGIN_VOLUME="$vol"
done < <(mount | grep -oi '/Volumes/Rakuten Claude Code Setup[^(]*' | sed 's/ *$//' | sort -V)

if [[ -z "$PLUGIN_VOLUME" ]]; then
  if [[ -f "${SCRIPT_DIR}/assets/rr-standards.zip" ]]; then
    PLUGIN_VOLUME="${SCRIPT_DIR}/assets"
  fi
fi

if [[ -n "$PLUGIN_VOLUME" ]] && [[ -f "${PLUGIN_VOLUME}/rr-standards.zip" ]]; then
  RR_TMP=/tmp/rr-standards-extract
  PLUGIN_DEST="/Library/Application Support/Claude/org-plugins"

  rm -rf "$RR_TMP" && mkdir -p "$RR_TMP"
  unzip -q "${PLUGIN_VOLUME}/rr-standards.zip" -d "$RR_TMP"

  INSTALL_CMD="mkdir -p '${PLUGIN_DEST}'"
  INSTALL_CMD+=" && rm -rf '${PLUGIN_DEST}/rr-standards' '${PLUGIN_DEST}/forge-skill-creator' '${PLUGIN_DEST}/forge'"
  INSTALL_CMD+=" && cp -R '${RR_TMP}/rr-standards-main/plugins/forge-skill-creator' '${PLUGIN_DEST}/'"
  INSTALL_CMD+=" && cp -R '${RR_TMP}/rr-standards-main/plugins/forge' '${PLUGIN_DEST}/'"

  OSASCRIPT_ERR=$(osascript 2>&1 <<OSASCRIPT
do shell script "${INSTALL_CMD}" with administrator privileges
OSASCRIPT
  )
  INSTALL_STATUS=$?
  rm -rf "$RR_TMP"

  if [[ $INSTALL_STATUS -eq 0 ]]; then
    ok "rr-standards plugin installed"
  else
    warn "Could not install rr-standards plugin: ${OSASCRIPT_ERR}"
  fi
else
  warn "rr-standards.zip not found — skipping plugin install"
fi

# ── step 5: install mobileconfig ──────────────────────────────────────────────

run "Opening configuration profile for installation..."

MOBILECONFIG_CONTENT='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
	<dict>
		<key>PayloadContent</key>
		<array>
			<dict>
				<key>PayloadType</key>
				<string>com.anthropic.claudefordesktop</string>
				<key>PayloadIdentifier</key>
				<string>com.anthropic.claudefordesktop.settings</string>
				<key>PayloadUUID</key>
				<string>0CBCAB4D-4E52-4C0C-A13C-FB31188A443A</string>
				<key>PayloadVersion</key>
				<integer>1</integer>
				<key>PayloadDisplayName</key>
				<string>Claude Desktop</string>
				<key>coworkEgressAllowedHosts</key>
				<string>["*"]</string>
				<key>inferenceProvider</key>
				<string>bedrock</string>
				<key>inferenceBedrockRegion</key>
				<string>us-east-1</string>
				<key>inferenceBedrockBearerToken</key>
				<string>{{BEARER_TOKEN}}</string>
				<key>inferenceBedrockBaseUrl</key>
				<string>https://api.ai.public.rakuten-it.com/claude-code-aws-bedrock/v1</string>
				<key>inferenceModels</key>
				<string>[{"name":"us.anthropic.claude-sonnet-4-6","supports1m":true}]</string>
				<key>banner</key>
				<string>{"enabled":true,"text":"Rakuten Rewards - Summit - v1.0.0","backgroundColor":"#1a1a1a","textColor":"#f0f0f0","linkUrl":"https://www.rakuten.com"}</string>
			</dict>
		</array>
		<key>PayloadDisplayName</key>
		<string>Rakuten Claude AI Configuration</string>
		<key>PayloadIdentifier</key>
		<string>com.anthropic.claudefordesktop.profile</string>
		<key>PayloadType</key>
		<string>Configuration</string>
		<key>PayloadUUID</key>
		<string>5294DE36-EBCB-4778-81DC-35849822638C</string>
		<key>PayloadVersion</key>
		<integer>1</integer>
		<key>PayloadScope</key>
		<string>User</string>
	</dict>
</plist>'

MOBILECONFIG_TMP=/tmp/Claude-summit-setup.mobileconfig
rm -f "$MOBILECONFIG_TMP"
trap 'sleep 3; rm -f "$MOBILECONFIG_TMP"' EXIT

PAT_SED=$(printf '%s' "$PAT" | sed 's/[&/\]/\\&/g')

printf '%s' "$MOBILECONFIG_CONTENT" \
  | sed "s|{{BEARER_TOKEN}}|${PAT_SED}|g" \
  > "$MOBILECONFIG_TMP"

open "$MOBILECONFIG_TMP"

ok "Configuration profile opened — click Install in System Settings"

# ── done ──────────────────────────────────────────────────────────────────────

printf "\n"
printf "  ${DIM}─────────────────────────────────────────${RESET}\n"
ok "Setup complete"
printf "\n"
printf "  ${DIM}Next steps:${RESET}\n"
printf "  ${DIM}1. Click${RESET} ${BOLD}Install${RESET}${DIM} in System Settings (profile window that just opened)${RESET}\n"
printf "  ${DIM}2. Open your project folder and run${RESET} ${BOLD}claude${RESET}${DIM} to start coding${RESET}\n"
printf "\n"
