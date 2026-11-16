#!/usr/bin/env bats

load helpers

setup() {
  setup_base
}

teardown() {
  teardown_base
}

@test "entrypoint initializes firewall flow and executes command" {
  export DDEV_APPROOT="$TEST_TMPDIR/app"
  mkdir -p "$DDEV_APPROOT/.ddev/claude/scripts"

  for s in merge-whitelist.sh resolve-and-apply.sh generate-settings.sh merge-denylist.sh check-secrets.sh watch-config.sh format-block-message.sh; do
    cat > "$DDEV_APPROOT/.ddev/claude/scripts/$s" <<'EOF'
#!/usr/bin/env bash
echo "$0 $*" >> /tmp/entrypoint-script-calls.log
exit 0
EOF
    chmod +x "$DDEV_APPROOT/.ddev/claude/scripts/$s"
  done

  mock_cmd git <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/entrypoint-git.log
exit 0
EOF
  mock_cmd iptables <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/entrypoint-iptables.log
exit 0
EOF
  mock_cmd ipset <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list" ]]; then
  echo "203.0.113.10 timeout 3000"
  exit 0
fi
echo "$*" >> /tmp/entrypoint-ipset.log
exit 0
EOF

  run bash "$REPO_ROOT/claude/entrypoint.sh" /bin/echo "entrypoint-ok"

  [ "$status" -eq 0 ]
  [[ "$output" == *"entrypoint-ok"* ]]
  run grep -c 'watch-config.sh' /tmp/entrypoint-script-calls.log
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  # hash:net, so whitelisted CIDR ranges are stored as single entries.
  run grep -c '^create -exist whitelist_ips hash:net timeout 3600$' /tmp/entrypoint-ipset.log
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "format-block-message prints friendly blocked domain output" {
  mock_cmd dmesg <<'EOF'
#!/usr/bin/env bash
echo "[FIREWALL-BLOCK] DST=203.0.113.42"
EOF
  mock_cmd dig <<'EOF'
#!/usr/bin/env bash
echo "blocked.example.test."
EOF

  run bash "$REPO_ROOT/claude/scripts/format-block-message.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Network request BLOCKED"* ]]
  [[ "$output" == *"blocked.example.test (203.0.113.42)"* ]]
}
