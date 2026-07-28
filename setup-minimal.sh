#!/bin/bash
set -euo pipefail

# Minimal superpowerd install: account rotation and the rate-limit monitor,
# nothing else.
#
# Unlike setup.sh this never installs packages, never clones repos, and never
# touches your terminal or window-manager config. It sets up only what
# `sp-rotate` needs to work. Suitable for Linux, WSL, and macOS, and for any
# machine where you don't want the WezTerm grid or the dashboard.
#
# Usage:
#   bash setup-minimal.sh                # rotation + monitor service
#   bash setup-minimal.sh --no-service   # rotation only, start monitor yourself
#   bash setup-minimal.sh --with-hook    # also auto-capture tokens on session start

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

INSTALL_SERVICE=true
INSTALL_HOOK=false
for arg in "$@"; do
  case "$arg" in
    --no-service) INSTALL_SERVICE=false ;;
    --with-hook)  INSTALL_HOOK=true ;;
    -h|--help)
      # Print the header comment block, stopping at the first line of code.
      awk 'NR>3 { if (/^#/) { sub(/^# ?/, ""); print } else { exit } }' "$0"
      exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

IS_DARWIN=false
[[ "$(uname)" == "Darwin" ]] && IS_DARWIN=true

echo ""
echo "  superpowerd minimal setup ($(uname))"
echo ""

# Prerequisites — report, don't install. Rotation needs node (tokens.js), the
# claude CLI (auth status / login), and a multiplexer to restart panes in.
echo "==> Prerequisites"
for tool in node claude; do
  if ! command -v "$tool" &>/dev/null; then
    echo "    ERROR: $tool not found — required. Install it and re-run."
    exit 1
  fi
  echo "    $tool: $(command -v "$tool")"
done

if command -v tmux &>/dev/null || command -v wezterm &>/dev/null; then
  echo "    multiplexer: $(command -v tmux || command -v wezterm)"
else
  echo "    WARNING: no tmux or wezterm found."
  echo "    Rotation will still swap credentials, but it can't find panes to"
  echo "    restart, so running Claude sessions won't pick up the new account."
fi

# Config
echo "==> Config"
if [[ ! -f "$PROJECT_DIR/accounts.conf" ]]; then
  cp "$PROJECT_DIR/accounts.conf.example" "$PROJECT_DIR/accounts.conf"
  echo "    Created accounts.conf — edit it with your accounts"
else
  echo "    accounts.conf already exists, left alone"
fi

mkdir -p "$PROJECT_DIR/data"
if [[ ! -f "$PROJECT_DIR/data/state.json" ]]; then
  echo '{"current": 0}' > "$PROJECT_DIR/data/state.json"
fi

chmod +x \
  "$PROJECT_DIR/rotation/rotate" \
  "$PROJECT_DIR/rotation/monitor" \
  "$PROJECT_DIR/rotation/tokens.js" \
  "$PROJECT_DIR/rotation/capture-hook"

# Shell aliases — appended to whichever rc file matches the login shell.
echo "==> Shell config"
case "${SHELL:-}" in
  */zsh) RC="$HOME/.zshrc" ;;
  */bash) RC="$HOME/.bashrc" ;;
  *) RC="$HOME/.profile" ;;
esac
touch "$RC"

if grep -q "SUPERPOWERD_HOME" "$RC"; then
  echo "    $(basename "$RC") already configured, left alone"
else
  cat >> "$RC" << BLOCK

# superpowerd (minimal: rotation + monitor)
export SUPERPOWERD_HOME="$PROJECT_DIR"
alias sp-rotate="$PROJECT_DIR/rotation/rotate"
alias sp-monitor="$PROJECT_DIR/rotation/monitor"
alias sp-tokens="node $PROJECT_DIR/rotation/tokens.js"
BLOCK
  echo "    Added SUPERPOWERD_HOME and sp-* aliases to $(basename "$RC")"
fi

# Capture whatever account is currently authenticated.
echo "==> Capturing current tokens"
if node "$PROJECT_DIR/rotation/tokens.js" capture 2>/dev/null; then
  echo "    Saved current account tokens"
else
  echo "    (no active session — run 'sp-tokens capture-all' once authenticated)"
fi

# Optional: capture tokens automatically whenever a Claude session starts, so a
# refreshed access token doesn't leave the stored copy stale.
if $INSTALL_HOOK; then
  echo "==> Auto-capture hook"
  SETTINGS_FILE="$HOME/.claude/settings.json"
  if [[ -f "$SETTINGS_FILE" ]]; then
    node -e "
      var fs = require('fs');
      var settings = JSON.parse(fs.readFileSync('$SETTINGS_FILE', 'utf8'));
      if (!settings.hooks) settings.hooks = {};
      if (!settings.hooks.SessionStart) settings.hooks.SessionStart = [];
      var exists = settings.hooks.SessionStart.some(function(h) {
        return h.hooks && h.hooks.some(function(hh) {
          return hh.command && hh.command.includes('capture-hook');
        });
      });
      if (exists) { console.log('    Hook already installed'); }
      else {
        settings.hooks.SessionStart.push({
          matcher: '',
          hooks: [{ type: 'command', command: '$PROJECT_DIR/rotation/capture-hook' }]
        });
        fs.writeFileSync('$SETTINGS_FILE', JSON.stringify(settings, null, 2) + '\n');
        console.log('    Installed SessionStart hook');
      }
    "
  else
    echo "    No $SETTINGS_FILE — skipped"
  fi
fi

# Monitor service
if $INSTALL_SERVICE; then
  echo "==> Monitor service"
  NODE_DIR="$(dirname "$(command -v node)")"

  if $IS_DARWIN; then
    PLIST="$HOME/Library/LaunchAgents/com.superpowerd.monitor.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.superpowerd.monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$PROJECT_DIR/rotation/monitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$PROJECT_DIR/data/monitor.log</string>
    <key>StandardErrorPath</key>
    <string>$PROJECT_DIR/data/monitor.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$NODE_DIR</string>
    </dict>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
      || launchctl load "$PLIST" 2>/dev/null || true
    echo "    Installed launchd service (com.superpowerd.monitor)"

  elif command -v systemctl &>/dev/null && systemctl --user show-environment &>/dev/null; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    # Foreground form, not --daemon: systemd supervises, and the script's
    # SIGTERM trap tears down its watchers and PID file on stop.
    cat > "$UNIT_DIR/superpowerd-monitor.service" << UNIT
[Unit]
Description=superpowerd rate limit monitor
After=default.target

[Service]
Type=simple
ExecStart=/bin/bash $PROJECT_DIR/rotation/monitor
Restart=on-failure
RestartSec=10
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$NODE_DIR

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now superpowerd-monitor.service
    echo "    Installed systemd user service (superpowerd-monitor)"
    echo "    Note: user services stop at logout unless lingering is enabled:"
    echo "      sudo loginctl enable-linger $(whoami)"

  else
    echo "    No launchd or systemd user session available."
    echo "    Start the monitor manually instead: sp-monitor --daemon"
  fi
fi

echo ""
echo "=== Minimal setup complete ==="
echo ""
echo "Commands:"
echo "  sp-rotate              Rotate to next account"
echo "  sp-rotate --status     Show current account and stored tokens"
echo "  sp-rotate --dry-run    Simulate a rotation, changing nothing"
echo "  sp-monitor --status    Check the monitor"
echo "  sp-tokens capture-all  Authenticate each account and store its tokens"
echo ""
echo "Next:"
echo "  1. Add your accounts to $PROJECT_DIR/accounts.conf"
echo "     (rotation needs at least two to have somewhere to go)"
echo "  2. Run: sp-tokens capture-all"
echo "  3. Restart your shell to pick up the aliases"
echo ""
