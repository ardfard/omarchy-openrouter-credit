#!/usr/bin/env bash
set -euo pipefail

# OpenRouter Credit — local installer for Omarchy
# Copies this repo (which IS the plugin folder) to ~/.config/omarchy/plugins/,
# validates it, rescans, and optionally adds it to the bar.

PLUGIN_ID="io.github.ardfard.openrouter-credit"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

echo "→ OpenRouter Credit installer"
echo "  Source: $SRC_DIR"
echo "  Dest:   $DEST_DIR"
echo ""

# 1. Check dependencies
if ! command -v omarchy >/dev/null 2>&1; then
  echo "✗ 'omarchy' not found. Are you on Omarchy?" >&2
  exit 1
fi
for dep in curl wl-copy; do
  command -v "$dep" >/dev/null 2>&1 || echo "⚠ '$dep' not found — the plugin needs it (curl: fetching; wl-copy: copy model id)"
done

# 2. Create dest & copy files (manifest + QML + JS are required)
mkdir -p "$DEST_DIR"
echo "→ Copying plugin files..."
cp -v "$SRC_DIR/manifest.json" "$SRC_DIR/BarWidget.qml" "$SRC_DIR/Panel.qml" "$SRC_DIR/Model.js" "$DEST_DIR/"
if [[ -d "$SRC_DIR/assets" ]]; then cp -rv "$SRC_DIR/assets" "$DEST_DIR/" 2>/dev/null || true; fi
cp -v "$SRC_DIR/README.md" "$SRC_DIR/LICENSE" "$DEST_DIR/" 2>/dev/null || true

# sanity: the shell refuses symlinked plugins
if [[ -L "$DEST_DIR/manifest.json" ]]; then echo "✗ symlink detected" >&2; exit 1; fi

# 3. Validate
echo ""
echo "→ Validating manifest..."
if ! omarchy plugin validate "$DEST_DIR"; then
  echo "✗ omarchy plugin validate failed" >&2
  exit 1
fi
echo "✓ manifest OK"

# 4. QML lint (best-effort — skipped if qmllint or the shell path is missing)
SHELL_PATH="${OMARCHY_PATH:+$OMARCHY_PATH/shell}"
[[ -d ${SHELL_PATH:-} ]] || SHELL_PATH="/usr/share/omarchy/shell"
if command -v qmllint >/dev/null 2>&1 && [[ -d $SHELL_PATH ]]; then
  echo "→ Linting QML..."
  qmllint -I "$SHELL_PATH" "$DEST_DIR/BarWidget.qml" "$DEST_DIR/Panel.qml"
  echo "✓ qmllint OK"
else
  echo "→ Skipping qmllint (qmllint or the Omarchy shell path not found)"
fi

# 5. Rescan plugins
echo ""
echo "→ Rescanning plugins..."
if command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins || echo "  (rescanPlugins failed — shell may not be running, continuing)"
else
  echo "  (omarchy-shell not found — skipping rescan)"
fi

# 6. Show status
echo ""
# `omarchy plugin list --json` emits compact JSON ("id":"..."), so match on the
# id alone rather than on a spaced key/value pair.
if omarchy plugin list --json 2>/dev/null | grep -q "\"$PLUGIN_ID\""; then
  echo "✓ Plugin discovered:"
  omarchy plugin list --json | jq --arg id "$PLUGIN_ID" '.[] | select(.id==$id) | {id, kinds, enabled}' 2>/dev/null || true
else
  echo "⚠ Plugin not yet listed — try: omarchy-shell shell rescanPlugins"
fi

# 7. Offer to add to the bar layout
SHELL_JSON="$HOME/.config/omarchy/shell.json"
if [[ -f "$SHELL_JSON" ]]; then
  if grep -q "\"$PLUGIN_ID\"" "$SHELL_JSON" 2>/dev/null; then
    echo ""
    echo "✓ Already in shell.json"
  else
    echo ""
    read -rp "Add '$PLUGIN_ID' to the bar (right section)? [Y/n] " ans
    ans=${ans:-Y}
    if [[ "$ans" =~ ^[Yy] ]]; then
      cp "$SHELL_JSON" "$SHELL_JSON.bak.$(date +%Y%m%d%H%M%S)"
      python3 - <<PY
import json, pathlib
p = pathlib.Path("$SHELL_JSON")
data = json.loads(p.read_text())
layout = data.setdefault("bar", {}).setdefault("layout", {})
right = layout.setdefault("right", [])
if not any(isinstance(e, dict) and e.get("id") == "$PLUGIN_ID" for e in right):
    right.append({"id": "$PLUGIN_ID"})
    p.write_text(json.dumps(data, indent=2) + "\n")
    print("✓ Added to bar.layout.right (backup created)")
else:
    print("already present")
PY
      echo "  Restart the shell: omarchy restart shell  (or log out and back in)"
    else
      echo "  Skipped — enable it manually in Omarchy bar settings or shell.json"
    fi
  fi
fi

echo ""
echo "Next: set your API key."
echo "  Either export OPENROUTER_API_KEY=sk-or-v1-... in your shell profile,"
echo "  or click the bar pill and paste the key into the panel's API key field."
echo ""
echo "Test:"
echo "  omarchy-shell shell summon $PLUGIN_ID '{}'"
echo "  omarchy-shell ipc call $PLUGIN_ID refresh"
