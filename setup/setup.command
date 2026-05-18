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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
step "2" "Install Git, VS Code, Claude Code extension, Claude Desktop, and plugins"
step "3" "Configure Claude Code automatically"
step "4" "Install Claude Desktop configuration profile"
step "5" "Install AI Summit plugin for Claude Desktop"
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

step_active "2" "Install Git, VS Code, Claude Code extension, Claude Desktop, and plugins"
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
  VSCODE_ZIP=/tmp/vscode-setup.zip
  rm -f "$VSCODE_ZIP"
  curl -fsSL --progress-bar \
    "https://update.code.visualstudio.com/latest/darwin-universal/stable" \
    -o "$VSCODE_ZIP" \
    || die "Failed to download VS Code."
  printf "\n"

  info "Installing VS Code..."
  unzip -q "$VSCODE_ZIP" -d /Applications/ \
    || die "Failed to install VS Code."
  rm -f "$VSCODE_ZIP"
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

# Node.js + npx via nvm
if ! command -v npx &>/dev/null; then
  info "Installing Node.js (includes npx)..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash \
    || warn "Could not install nvm. Visit https://nodejs.org for instructions."
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"
  nvm install --lts 2>/dev/null \
    || warn "Could not install Node.js via nvm."
  export PATH="$NVM_DIR/versions/node/$(nvm current 2>/dev/null)/bin:$PATH"
else
  info "Node.js already installed ($(node --version 2>/dev/null || true))."
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

# Claude Desktop
if [[ ! -d "/Applications/Claude.app" ]]; then
  info "Downloading Claude Desktop (317 MB)..."
  CLAUDE_DMG=/tmp/Claude-setup.dmg
  rm -f "$CLAUDE_DMG"
  curl -fsSL \
    "https://downloads.claude.ai/releases/darwin/universal/1.5354.0/Claude-9a9e3d5a4a368f0f49a80dc303b0ed1a18bfedad.dmg" \
    -o "$CLAUDE_DMG" &
  CURL_PID=$!
  frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  i=0
  while kill -0 "$CURL_PID" 2>/dev/null; do
    printf "\r      ${CYAN}${frames[$((i % 10))]}${RESET}  ${DIM}Downloading...${RESET}   "
    sleep 0.2
    i=$(( i + 1 ))
  done
  printf "\r\033[2K"
  if ! wait "$CURL_PID"; then
    warn "Failed to download Claude Desktop — install manually from https://claude.ai/download"
  else
    info "Installing Claude Desktop..."
    CLAUDE_MOUNT=$(hdiutil attach "$CLAUDE_DMG" -nobrowse -noverify -plist 2>/dev/null \
      | python3 -c "import sys,plistlib,io; d=plistlib.load(io.BytesIO(sys.stdin.buffer.read())); print([e['mount-point'] for e in d['system-entities'] if 'mount-point' in e][-1])" 2>/dev/null || true)
    if [[ -d "$CLAUDE_MOUNT/Claude.app" ]]; then
      cp -R "$CLAUDE_MOUNT/Claude.app" /Applications/
      hdiutil detach "$CLAUDE_MOUNT" -quiet 2>/dev/null || true
      info "Claude Desktop installed."
    else
      warn "Could not install Claude Desktop — install manually from https://claude.ai/download"
    fi
    rm -f "$CLAUDE_DMG"
  fi
else
  info "Claude Desktop already installed."
fi

clear_lines 2
step_done "2" "Git, VS Code, Claude Code extension, Claude Desktop, and Node.js ready"

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

# ── step 3b: install Claude plugins (needs settings.json to be present) ───────

step_active "3" "Installing Claude plugins"
printf "\n"

if command -v claude &>/dev/null; then
  info "Installing skill-creator plugin..."
  claude plugin install skill-creator@claude-plugins-official --scope user 2>/dev/null \
    || warn "Could not install skill-creator — run manually: claude plugin install skill-creator@claude-plugins-official --scope user"
else
  warn "'claude' CLI not found — skipping plugin install. After installing Claude Code, run:\n        claude plugin add anthropics/claude-plugins-official\n        claude plugin install skill-creator@claude-plugins-official --scope user"
fi

clear_lines 2
step_done "3" "Claude plugins installed"

# ── step 4: install Claude Desktop mobileconfig ───────────────────────────────

MOBILECONFIG_FALLBACK='<?xml version="1.0" encoding="UTF-8"?>
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
				<key>managedMcpServers</key>
				<string>[{"name":"Slack","toolPolicy":{"slack_search_public":"allow","slack_search_public_and_private":"allow","slack_search_channels":"allow","slack_search_users":"allow","slack_read_channel":"allow","slack_read_thread":"allow","slack_read_canvas":"allow","slack_read_user_profile":"allow","slack_list_channel_members":"allow","slack_read_file":"allow","slack_search_emojis":"allow","slack_get_reactions":"allow"},"source":"user","transport":"http","url":"https://mcp.slack.com/mcp","oauth":{"clientId":"1601185624273.8899143856786","callbackPort":3118,"callbackHost":"localhost"}},{"name":"datadog-prod","toolPolicy":{"analyze_datadog_logs":"allow","get_datadog_dashboard":"allow","get_datadog_incident":"allow","get_datadog_metric":"allow","get_datadog_metric_context":"allow","get_datadog_notebook":"allow","get_datadog_trace":"allow","get_widget_reference":"allow","list_datadog_skills":"allow","load_datadog_skill":"allow","search_datadog_dashboards":"allow","search_datadog_events":"allow","search_datadog_hosts":"allow","search_datadog_incidents":"allow","search_datadog_logs":"allow","search_datadog_metrics":"allow","search_datadog_monitors":"allow","search_datadog_notebooks":"allow","search_datadog_rum_events":"allow","search_datadog_service_dependencies":"allow","search_datadog_services":"allow","search_datadog_spans":"allow"},"source":"user","transport":"http","url":"https://mcp.datadoghq.com/api/unstable/mcp-server/mcp","oauth":true},{"name":"atlassian","toolPolicy":{"atlassianUserInfo":"allow","getConfluencePage":"allow","searchConfluenceUsingCql":"allow","getConfluenceSpaces":"allow","getPagesInConfluenceSpace":"allow","getConfluencePageFooterComments":"allow","getConfluencePageInlineComments":"allow","getConfluenceCommentChildren":"allow","getConfluencePageDescendants":"allow","getJiraIssue":"allow","getTransitionsForJiraIssue":"allow","getJiraIssueRemoteIssueLinks":"allow","getVisibleJiraProjects":"allow","getJiraProjectIssueTypesMetadata":"allow","getJiraIssueTypeMetaWithFields":"allow","searchJiraIssuesUsingJql":"allow","lookupJiraAccountId":"allow","getIssueLinkTypes":"allow","search":"allow","fetch":"allow"},"source":"user","transport":"http","url":"https://mcp.atlassian.com/v1/mcp","oauth":true},{"name":"monday-com","toolPolicy":{"get_board_items_page":"allow","get_updates":"allow","get_board_activity":"allow","get_board_info":"allow","get_full_board_data":"allow","list_users_and_teams":"allow","get_form":"allow","get_graphql_schema":"allow","get_column_type_info":"allow","get_type_details":"allow","read_docs":"allow","workspace_info":"allow","list_workspaces":"allow","all_widgets_schema":"allow","board_insights":"allow","search":"allow","get_user_context":"allow","get_assets":"allow","get_notetaker_meetings":"allow","get_agent":"allow","get_monday_dev_sprints_boards":"allow","get_sprints_metadata":"allow","get_sprint_summary":"allow"},"source":"user","transport":"sse","url":"https://mcp.monday.com/sse","oauth":true},{"name":"uber-context","source":"user","transport":"http","url":"https://uber-context-system.shared-np.rr-it.com/mcp"},{"name":"browserStack","source":"user","transport":"http","url":"https://mcp.browserstack.com/mcp","oauth":true},{"name":"datadog-nonprod","toolPolicy":{"analyze_datadog_logs":"allow","get_datadog_dashboard":"allow","get_datadog_incident":"allow","get_datadog_metric":"allow","get_datadog_metric_context":"allow","get_datadog_notebook":"allow","get_datadog_trace":"allow","get_widget_reference":"allow","list_datadog_skills":"allow","load_datadog_skill":"allow","search_datadog_dashboards":"allow","search_datadog_events":"allow","search_datadog_hosts":"allow","search_datadog_incidents":"allow","search_datadog_logs":"allow","search_datadog_metrics":"allow","search_datadog_monitors":"allow","search_datadog_notebooks":"allow","search_datadog_rum_events":"allow","search_datadog_service_dependencies":"allow","search_datadog_services":"allow","search_datadog_spans":"allow"},"source":"user","transport":"http","url":"https://mcp.datadoghq.com/api/unstable/mcp-server/mcp","oauth":true},{"name":"figma","toolPolicy":{"get_design_context":"allow","get_variable_defs":"allow","get_screenshot":"allow","get_code_connect_map":"allow","add_code_connect_map":"allow","get_code_connect_suggestions":"allow","send_code_connect_mappings":"allow","get_metadata":"allow","create_design_system_rules":"allow","get_figjam":"allow"},"source":"user","transport":"sse","url":"http://127.0.0.1:3845/sse"},{"name":"iterable","source":"user","transport":"stdio","command":"{{NPX_PATH}}","args":["@iterable/mcp"],"env":{"ITERABLE_API_KEY":"{{ITERABLE_API_KEY}}","ITERABLE_BASE_URL":"https://api.iterable.com","ITERABLE_ENABLE_WRITES":"true"}},{"name":"annalise-rewards","toolPolicy":{"get_domain":"allow","list_entities":"allow","list_domains":"allow","monitor_analysis":"allow","get_analysis_step_details":"allow","get_entity":"allow","initiate_analysis":"allow","get_field":"allow","search_model":"allow","list_databases":"allow","list_shemas":"allow","list_tables":"allow","get_table_info":"allow","list_workspaces":"allow","list_workspace_branches":"allow","get_session_workspace_and_branch":"allow","get_branch_history":"allow","list_agents":"allow","get_agents":"allow","list_context_items":"allow","get_context_items":"allow"},"source":"user","transport":"http","url":"https://mcp.rakuten.honeydew.cloud/mcp","oauth":true}]</string>
			</dict>
		</array>
		<key>PayloadDisplayName</key>
		<string>Claude Desktop Third-Party Inference</string>
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

step_active "4" "Install Claude Desktop configuration profile"
info "Preparing configuration profile..."

MOBILECONFIG_TMP=/tmp/Claude-setup.mobileconfig
rm -f "$MOBILECONFIG_TMP"
trap 'sleep 3; rm -f "$MOBILECONFIG_TMP"' EXIT

PAT_SED=$(printf '%s' "$PAT" | sed 's/[&/\]/\\&/g')

ITERABLE_API_KEY=$(printf '%s' "V2xSQmVrOUhXVEpPUkdjMFRYcHNhMDVFUW0xTlYwVjRXbGRTYWxwdFJUTlplbXhwV2xSUk1GbDZRVDA5" \
  | base64 -d | base64 -d | base64 -d 2>/dev/null || true)
ITERABLE_SED=$(printf '%s' "$ITERABLE_API_KEY" | sed 's/[&/\]/\\&/g')

export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
NPX_PATH=$(command -v npx 2>/dev/null || true)
NPX_SED=$(printf '%s' "$NPX_PATH" | sed 's/[&/\]/\\&/g')

MOBILECONFIG_ASSET="$SCRIPT_DIR/assets/claude-desktop.mobileconfig"

if [[ -f "$MOBILECONFIG_ASSET" ]]; then
  MOBILECONFIG_SRC=$(cat "$MOBILECONFIG_ASSET")
else
  warn "Asset file not found at $MOBILECONFIG_ASSET — using fallback profile."
  MOBILECONFIG_SRC="$MOBILECONFIG_FALLBACK"
fi

printf '%s' "$MOBILECONFIG_SRC" \
  | sed "s|{{BEARER_TOKEN}}|${PAT_SED}|g" \
  | sed "s|{{ITERABLE_API_KEY}}|${ITERABLE_SED}|g" \
  | sed "s|{{NPX_PATH}}|${NPX_SED}|g" \
  | sed "s|\$USER|${USER}|g" \
  > "$MOBILECONFIG_TMP"

open "$MOBILECONFIG_TMP"

step_done "4" "Configuration profile opened — click Install in System Settings"

# ── step 5: install ai-summit org-plugin ──────────────────────────────────────

step_active "5" "Install AI Summit plugin for Claude Desktop"
info "Copying plugin to /Library/Application Support/Claude/org-plugins/..."

PLUGIN_DEST="/Library/Application Support/Claude/org-plugins"
PLUGIN_VOLUME=$(mount | grep -o '/Volumes/Rakuten Claude Code Setup[^(]*' | sed 's/ $//' | head -1)
PLUGIN_SRC="${PLUGIN_VOLUME}/ai-summit"

OSASCRIPT_ERR=$(osascript 2>&1 <<OSASCRIPT
do shell script "mkdir -p '${PLUGIN_DEST}' && rm -rf '${PLUGIN_DEST}/ai-summit' && cp -R '${PLUGIN_SRC}' '${PLUGIN_DEST}/'" with administrator privileges
OSASCRIPT
)
if [[ $? -eq 0 ]]; then
  step_done "5" "AI Summit plugin installed"
else
  warn "Could not install AI Summit plugin: ${OSASCRIPT_ERR}"
  warn "Copy '${PLUGIN_SRC}' to '${PLUGIN_DEST}' manually"
fi

# rr-standards + forge plugins
RR_ZIP="${PLUGIN_VOLUME}/rr-standards.zip"
RR_TMP=/tmp/rr-standards-extract
if [[ -f "$RR_ZIP" ]]; then
  rm -rf "$RR_TMP" && mkdir -p "$RR_TMP"
  unzip -q "$RR_ZIP" -d "$RR_TMP"
  OSASCRIPT_RR_ERR=$(osascript 2>&1 <<OSASCRIPT
do shell script "rm -rf '${PLUGIN_DEST}/rr-standards' '${PLUGIN_DEST}/forge' && cp -R '${RR_TMP}/rr-standards-main/plugins/rr-standards' '${PLUGIN_DEST}/' && cp -R '${RR_TMP}/rr-standards-main/plugins/forge' '${PLUGIN_DEST}/'" with administrator privileges
OSASCRIPT
  )
  RR_STATUS=$?
  rm -rf "$RR_TMP"
  if [[ $RR_STATUS -eq 0 ]]; then
    step_done "5" "rr-standards + forge plugins installed"
  else
    warn "Could not install rr-standards/forge plugins: ${OSASCRIPT_RR_ERR}"
  fi
fi

# honeydew-ai-claude plugin
info "Installing honeydew-ai-claude plugin..."
HD_ZIP="${PLUGIN_VOLUME}/honeydew-ai-claude.zip"
HD_TMP=/tmp/honeydew-ai-claude-extract
if [[ -f "$HD_ZIP" ]]; then
  rm -rf "$HD_TMP" && mkdir -p "$HD_TMP/honeydew-ai-claude"
  unzip -q "$HD_ZIP" -d "$HD_TMP/honeydew-ai-claude"
  OSASCRIPT_HD_ERR=$(osascript 2>&1 <<OSASCRIPT
do shell script "rm -rf '${PLUGIN_DEST}/honeydew-ai-claude' && cp -R '${HD_TMP}/honeydew-ai-claude' '${PLUGIN_DEST}/'" with administrator privileges
OSASCRIPT
  )
  HD_STATUS=$?
  rm -rf "$HD_TMP"
  if [[ $HD_STATUS -eq 0 ]]; then
    step_done "5" "honeydew-ai-claude plugin installed"
  else
    warn "Could not install honeydew-ai-claude plugin: ${OSASCRIPT_HD_ERR}"
  fi
else
  warn "honeydew-ai-claude.zip not found on volume — skipping"
fi

# ── summary ────────────────────────────────────────────────────────────────────

printf "\n"
printf "  ${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${RESET}\n"
printf "  ${BOLD}${GREEN}║                  Setup Complete! 🎉                  ║${RESET}\n"
printf "  ${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${RESET}\n"
printf "\n"
printf "  ${WHITE}Next steps:${RESET}\n"
printf "  ${DIM}1. Click ${RESET}${BOLD}Install${RESET}${DIM} in the System Settings window that just opened${RESET}\n"
printf "  ${DIM}2. Open VS Code in your project folder${RESET}\n"
printf "  ${DIM}3. Press ${RESET}${BOLD}Cmd+Shift+P${RESET}${DIM} → \"Claude: Open Chat\" to start coding${RESET}\n"
printf "\n"
