#!/usr/bin/env bats

load helpers

setup() {
  setup_base
}

teardown() {
  teardown_base
}

@test "install.yaml ensures .claude.json exists for bind mount" {
  run grep -F '[ -f ~/.claude.json ] || echo' "$REPO_ROOT/install.yaml"
  [ "$status" -eq 0 ]
}

@test "install.yaml ensures .gitconfig exists for bind mount" {
  run grep -F '[ -f ~/.gitconfig ] || touch ~/.gitconfig' "$REPO_ROOT/install.yaml"
  [ "$status" -eq 0 ]
}

@test "install.yaml ensures .config/git directory exists for bind mount" {
  run grep -F 'mkdir -p ~/.config/git' "$REPO_ROOT/install.yaml"
  [ "$status" -eq 0 ]
}

@test "install.yaml declares the Lullabot/ddev-gitleaks add-on dependency" {
  run grep -F -- '- Lullabot/ddev-gitleaks' "$REPO_ROOT/install.yaml"
  [ "$status" -eq 0 ]
}
