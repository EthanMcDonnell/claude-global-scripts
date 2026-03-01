# claude-global-scripts
Scripts for `~/.claude/scripts`

## Status Bar Setup

Manually set up the Claude Code status bar to display model, context usage, and cost at a glance — no more typing `/usage` to check where you're at.

### Steps

**1. Copy the script**

Copy `context-bar.sh` from this repo into `~/.claude/scripts/`:

```bash
cp context-bar.sh ~/.claude/scripts/context-bar.sh
```

**2. Make it executable**

```bash
chmod +x ~/.claude/scripts/context-bar.sh
```

**3. Update `~/.claude/settings.json`**

Add the following to your `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/scripts/context-bar.sh"
  }
}
```

If you already have other settings in the file, add the `statusLine` block alongside them.

**4. Restart Claude Code**

The status bar will appear at the bottom of your terminal session.

### Dependencies

Requires `jq` for JSON parsing:

```bash
brew install jq       # macOS
apt install jq        # Linux
```
