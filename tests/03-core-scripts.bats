#!/usr/bin/env bats

load helpers

setup() {
  setup_base
  make_test_approot
}

teardown() {
  teardown_base
}

@test "exempt-secret writes unique session overrides" {
  run bash "$REPO_ROOT/claude/bin/exempt-secret" ".env" ".env" "/project/.pgpass"

  [ "$status" -eq 0 ]
  run grep -c '^\.env$' /tmp/ddev-claude-secret-override
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  run grep -c '^/project/\.pgpass$' /tmp/ddev-claude-secret-override
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "add-domain appends whitelist and updates ipset/cache" {
  mock_cmd dig <<'EOF'
#!/usr/bin/env bash
echo "203.0.113.10"
EOF
  mock_cmd ipset <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/ipset-calls.log
exit 0
EOF

  export DDEV_APPROOT
  DDEV_APPROOT="$TEST_TMPDIR/app"

  run bash "$REPO_ROOT/claude/bin/add-domain" "api.example.test"

  [ "$status" -eq 0 ]
  run jq -r '.[]' "$DDEV_APPROOT/.ddev/ddev-claude/whitelist.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"api.example.test"* ]]
  run grep -c 'add -exist whitelist_ips 203.0.113.10 timeout 3600' /tmp/ipset-calls.log
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  run grep -c '^api\.example\.test$' /tmp/ddev-claude-merged-whitelist.txt
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "resolve-and-apply resolves domains and skips failures" {
  mock_cmd dig <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "ok.example.test" ]]; then
  echo "198.51.100.20"
fi
EOF
  mock_cmd ipset <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/ipset-calls.log
exit 0
EOF

  whitelist_file="$TEST_TMPDIR/domains.txt"
  cat > "$whitelist_file" <<'EOF'
# comment
ok.example.test
missing.example.test
EOF

  run bash "$REPO_ROOT/claude/resolve-and-apply.sh" "$whitelist_file"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ok.example.test -> 198.51.100.20"* ]]
  [[ "$output" == *"Could not resolve missing.example.test"* ]]
  run grep -c 'add -exist whitelist_ips 198.51.100.20 timeout 3600' /tmp/ipset-calls.log
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "resolve-and-apply whitelists IP addresses and CIDR ranges without DNS" {
  mock_cmd dig <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >> "$TEST_TMPDIR/dig-calls.log"
EOF
  mock_cmd ipset <<'EOF'
#!/usr/bin/env bash
echo "$*" >> /tmp/ipset-calls.log
exit 0
EOF

  whitelist_file="$TEST_TMPDIR/domains.txt"
  cat > "$whitelist_file" <<'EOF'
192.0.2.0/24
203.0.113.7
10.0.0.0/4
999.1.1.1
EOF

  run bash "$REPO_ROOT/claude/resolve-and-apply.sh" "$whitelist_file"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Whitelisted: 192.0.2.0/24"* ]]
  [[ "$output" == *"Whitelisted: 203.0.113.7"* ]]
  [[ "$output" == *"Invalid IP address or range 10.0.0.0/4"* ]]
  [[ "$output" == *"Invalid IP address or range 999.1.1.1"* ]]
  run grep -c '^add -exist whitelist_ips 192.0.2.0/24 timeout 3600$' /tmp/ipset-calls.log
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  run grep -c '^add -exist whitelist_ips 203.0.113.7 timeout 3600$' /tmp/ipset-calls.log
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
  # Invalid entries never reach ipset, and nothing here is sent to DNS.
  run grep -cE '10\.0\.0\.0/4|999\.1\.1\.1' /tmp/ipset-calls.log
  [ "$output" -eq 0 ]
  [ ! -e "$TEST_TMPDIR/dig-calls.log" ]
}

@test "reload-whitelist flushes ipset and reapplies merged domains" {
  mock_cmd ipset <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "list" ]]; then
  cat <<'LIST'
Name: whitelist_ips
Members:
198.51.100.20 timeout 3500
LIST
  exit 0
fi
echo "$*" >> /tmp/ipset-calls.log
exit 0
EOF
  mock_cmd dig <<'EOF'
#!/usr/bin/env bash
echo "198.51.100.20"
EOF

  run bash "$REPO_ROOT/claude/scripts/reload-whitelist.sh"

  [ "$status" -eq 0 ]
  run grep -c '^flush whitelist_ips$' /tmp/ipset-calls.log
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  # The CIDR range in the default whitelist passes validation and is applied.
  run grep -c '^add -exist whitelist_ips 140.82.112.0/20 timeout 3600$' /tmp/ipset-calls.log
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "check-secrets warns when denied files are found" {
  printf '.env\n' > /tmp/ddev-claude-deny-patterns.txt
  : > /tmp/ddev-claude-allow-patterns.txt

  echo "secret=1" > "$DDEV_APPROOT/.env"

  run bash "$REPO_ROOT/claude/scripts/check-secrets.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"SECRET FILES DETECTED"* ]]
  [[ "$output" == *".env"* ]]
}

@test "ddev shim forwards runtime commands (php)" {
  run bash "$REPO_ROOT/claude/bin/ddev" php --version

  [ "$status" -eq 0 ]
  [[ "$output" == *"PHP"* ]]
}

@test "ddev shim forwards runtime commands (node)" {
  run bash "$REPO_ROOT/claude/bin/ddev" node --version

  [ "$status" -eq 0 ]
  [[ "$output" == *"v"* ]]
}

@test "ddev shim forwards runtime commands (composer)" {
  run bash "$REPO_ROOT/claude/bin/ddev" composer --version

  [ "$status" -eq 0 ]
  [[ "$output" == *"Composer"* ]]
}

@test "ddev shim blocks lifecycle commands (restart)" {
  status=0
  output="$(bash "$REPO_ROOT/claude/bin/ddev" restart 2>&1)" || status=$?

  [ "$status" -eq 127 ]
  [[ "$output" == *"Lifecycle commands must run on the host"* ]]
  [[ "$output" == *"ddev restart"* ]]
}

@test "ddev shim blocks lifecycle commands (exec)" {
  status=0
  output="$(bash "$REPO_ROOT/claude/bin/ddev" exec -s web php -v 2>&1)" || status=$?

  [ "$status" -eq 127 ]
  [[ "$output" == *"Lifecycle commands must run on the host"* ]]
  [[ "$output" == *"ddev exec -s web php -v"* ]]
}
