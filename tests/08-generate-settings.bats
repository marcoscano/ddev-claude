#!/usr/bin/env bats

load helpers

setup() {
  setup_base
  make_test_approot
}

teardown() {
  teardown_base
}

@test "generate-settings writes hooks to project .claude/settings.local.json" {
  run bash "$REPO_ROOT/claude/scripts/generate-settings.sh"

  [ "$status" -eq 0 ]
  [ -f "$DDEV_APPROOT/.claude/settings.local.json" ]
  run jq '.hooks.PreToolUse | length' "$DDEV_APPROOT/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "generate-settings does not touch global settings.json" {
  mkdir -p "$HOME/.claude"
  echo '{"existing": true}' > "$HOME/.claude/settings.json"

  run bash "$REPO_ROOT/claude/scripts/generate-settings.sh"

  [ "$status" -eq 0 ]
  # Global settings must be unchanged
  run jq -r '.existing' "$HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  # Must not have hooks in global settings
  run jq '.hooks // null' "$HOME/.claude/settings.json"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}

@test "generate-settings hook commands are conditional (contain test -f guard)" {
  run bash "$REPO_ROOT/claude/scripts/generate-settings.sh"

  [ "$status" -eq 0 ]
  run jq -r '.hooks.PreToolUse[].hooks[].command' "$DDEV_APPROOT/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test -f /opt/ddev-claude/hooks/url-check.sh"* ]]
  [[ "$output" == *"test -f /opt/ddev-claude/hooks/secret-check.sh"* ]]
  [[ "$output" == *"|| exit 0"* ]]
}

@test "generate-settings is idempotent (no duplicates on re-run)" {
  run bash "$REPO_ROOT/claude/scripts/generate-settings.sh"
  [ "$status" -eq 0 ]

  run bash "$REPO_ROOT/claude/scripts/generate-settings.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already registered"* ]]

  run jq '.hooks.PreToolUse | length' "$DDEV_APPROOT/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "generate-settings preserves existing settings.local.json content" {
  mkdir -p "$DDEV_APPROOT/.claude"
  echo '{"permissions": {"allow": ["Read"]}}' > "$DDEV_APPROOT/.claude/settings.local.json"

  run bash "$REPO_ROOT/claude/scripts/generate-settings.sh"

  [ "$status" -eq 0 ]
  run jq -r '.permissions.allow[0]' "$DDEV_APPROOT/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" = "Read" ]
  run jq '.hooks.PreToolUse | length' "$DDEV_APPROOT/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "generate-settings registers db-conn-check PostToolUse hook" {
  run bash "$REPO_ROOT/claude/scripts/generate-settings.sh"
  [ "$status" -eq 0 ]

  run jq -r '.hooks.PostToolUse[].hooks[].command' "$DDEV_APPROOT/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test -f /opt/ddev-claude/hooks/db-conn-check.sh"* ]]
  [[ "$output" == *"|| exit 0"* ]]

  run jq '.hooks.PostToolUse | length' "$DDEV_APPROOT/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}
