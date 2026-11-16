#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Integration tests for ddev-claude addon.
# Requires a real DDEV environment — run via CI with ddev/github-action-add-on-test@v2
# or locally with: bats tests/integration/test.bats
#
# IMPORTANT: Tests are order-dependent. The first test creates the DDEV project;
# subsequent tests operate on it. Do NOT use bats --jobs (parallel mode).

PROJNAME="ddev-claude-test"
TESTDIR="/tmp/$PROJNAME"

# Helper: assert last `run` command succeeded; prints output on failure.
assert_success() {
  if [ "$status" -ne 0 ]; then
    echo "FAILED (status=$status): $output" >&2
    return 1
  fi
}

setup() {
  set -eu -o pipefail
  export DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

teardown() {
  set -eu -o pipefail
  cd "$DIR" || true
}

teardown_file() {
  # Cleanup is best-effort; do not use set -e here.
  cd "/tmp/$PROJNAME" 2>/dev/null && ddev delete -Oy 2>/dev/null || true
  cd /
  # Docker-created files are root-owned on Linux; use sudo if available.
  sudo rm -rf "/tmp/$PROJNAME" 2>/dev/null || rm -rf "/tmp/$PROJNAME" 2>/dev/null || true
}

@test "install from directory" {
  mkdir -p "$TESTDIR"
  cd "$TESTDIR"

  # Create a minimal DDEV project
  ddev config --project-name="$PROJNAME" --project-type=php --docroot=web
  mkdir -p web
  echo '<?php echo "test";' > web/index.php

  # Install addon from repo checkout
  ddev get "$DIR"
  ddev restart
}

@test "claude container is running" {
  cd "$TESTDIR"

  # Simple check: can we exec into the claude service?
  run ddev exec -s claude true
  [ "$status" -eq 0 ]
}

@test "healthcheck passes" {
  cd "$TESTDIR"
  run ddev exec -s claude bash -c '${DDEV_APPROOT}/.ddev/claude/healthcheck.sh'
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthcheck passed"* ]]
}

@test "firewall blocks non-whitelisted traffic" {
  cd "$TESTDIR"
  # TEST-NET-2 (198.51.100.0/24) is reserved and never routable.
  # Curl should fail because the firewall drops outbound to non-whitelisted IPs.
  run ddev exec -s claude curl --max-time 3 -s http://198.51.100.1 2>&1
  [ "$status" -ne 0 ]
}

@test "whitelisted IP ranges are loaded into the ipset" {
  cd "$TESTDIR"
  # The default whitelist ships GitHub's range. The hash:net set keeps it as
  # one entry instead of one entry per address.
  run ddev exec -s claude ipset list whitelist_ips
  [ "$status" -eq 0 ]
  [[ "$output" == *"Type: hash:net"* ]]
  [[ "$output" == *"140.82.112.0/20 timeout"* ]]
}

@test "DNS resolution works" {
  cd "$TESTDIR"
  run ddev exec -s claude dig +short api.anthropic.com
  [ "$status" -eq 0 ]
  # Verify output looks like an IP address
  [[ "$output" =~ ^[0-9]+\.[0-9]+ ]]
}

@test ".env file is masked inside claude container" {
  cd "$TESTDIR"

  # Remove any existing .env file and create a new one with fake secrets
  rm -f .env
  cat > .env << 'EOF'
SECRET_KEY=super-secret-value-123
DB_PASSWORD=do-not-leak-this
EOF

  # Verify the file has content on the host
  [ -s .env ]
  grep -q "SECRET_KEY" .env

  # Restart containers so Docker can establish bind mount over the new .env file
  ddev restart >/dev/null

  # The critical security test: secrets are NOT visible inside container
  run ddev exec -s claude bash -c 'grep "SECRET_KEY" ${DDEV_APPROOT}/.env' 2>&1
  [ "$status" -ne 0 ]

  run ddev exec -s claude bash -c 'grep "DB_PASSWORD" ${DDEV_APPROOT}/.env' 2>&1
  [ "$status" -ne 0 ]
}

@test ".ddev/.env file is masked inside claude container" {
  cd "$TESTDIR"

  # Remove any existing .ddev/.env file and create a new one with DDEV-specific secrets
  rm -f .ddev/.env
  cat > .ddev/.env << 'EOF'
DDEV_ROUTER_HTTP_PORT=8080
ADMIN_TOKEN=sensitive-admin-token
EOF

  # Verify the file has content on the host
  [ -s .ddev/.env ]
  grep -q "ADMIN_TOKEN" .ddev/.env

  # Restart containers so Docker can establish bind mount over the new .ddev/.env file
  ddev restart >/dev/null

  # The critical security test: secrets are NOT visible inside container
  run ddev exec -s claude bash -c 'grep "ADMIN_TOKEN" ${DDEV_APPROOT}/.ddev/.env' 2>&1
  [ "$status" -ne 0 ]

  run ddev exec -s claude bash -c 'grep "DDEV_ROUTER_HTTP_PORT" ${DDEV_APPROOT}/.ddev/.env' 2>&1
  [ "$status" -ne 0 ]
}

@test "ddev shim forwards runtime command: php" {
  cd "$TESTDIR"

  # Runtime commands should be forwarded and execute successfully
  run ddev exec -s claude ddev php --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"PHP"* ]]
}

@test "ddev shim forwards runtime command: composer" {
  cd "$TESTDIR"

  run ddev exec -s claude ddev composer --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"Composer"* ]]
}

@test "ddev shim forwards runtime command: node" {
  cd "$TESTDIR"

  run ddev exec -s claude ddev node --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"v"* ]]
}

@test "ddev shim forwards runtime command: npm" {
  cd "$TESTDIR"

  run ddev exec -s claude ddev npm --version
  [ "$status" -eq 0 ]
  # npm version output is just the version number
  [[ "$output" =~ ^[0-9]+\.[0-9]+ ]]
}

@test "ddev lifecycle commands are blocked: restart" {
  cd "$TESTDIR"

  # Lifecycle commands should be blocked with helpful error
  run -127 ddev exec -s claude ddev restart 2>&1
  [ "$status" -eq 127 ]
  [[ "$output" == *"Lifecycle commands must run on the host"* ]]
  [[ "$output" == *"ddev restart"* ]]
}

@test "ddev lifecycle commands are blocked: exec" {
  cd "$TESTDIR"

  # exec is a lifecycle command and should be blocked
  run -127 ddev exec -s claude ddev exec -s web php -v 2>&1
  [ "$status" -eq 127 ]
  [[ "$output" == *"Lifecycle commands must run on the host"* ]]
  [[ "$output" == *"ddev exec -s web php -v"* ]]
}

@test "ddev shim is in PATH inside claude container" {
  cd "$TESTDIR"

  # Verify ddev command exists and is our shim
  run ddev exec -s claude which ddev
  [ "$status" -eq 0 ]
  [[ "$output" == *"/usr/local/bin/ddev"* ]]
}

@test "git config files are mounted inside claude container" {
  cd "$TESTDIR"

  # Verify git config file paths are mounted (even if empty)
  run ddev exec -s claude test -f /root/.gitconfig
  [ "$status" -eq 0 ]

  run ddev exec -s claude test -d /root/.config/git
  [ "$status" -eq 0 ]

  run ddev exec -s claude test -f /home/claude/.gitconfig
  [ "$status" -eq 0 ]

  run ddev exec -s claude test -d /home/claude/.config/git
  [ "$status" -eq 0 ]
}

@test "check which user runs commands in claude container" {
  cd "$TESTDIR"

  # Debug: Check which user is actually running commands
  run ddev exec -s claude whoami
  echo "Current user: $output"

  run ddev exec -s claude id
  echo "User ID info: $output"

  # Check git version to ensure it's installed
  run ddev exec -s claude git --version
  [ "$status" -eq 0 ]
  echo "Git version: $output"
}

@test "git commit succeeds inside claude container with repo-level config" {
  cd "$TESTDIR"

  # Check if git repo exists, if not initialize it
  run ddev exec -s claude test -d .git
  if [ "$status" -ne 0 ]; then
    run ddev exec -s claude git init
    assert_success
    run ddev exec -s claude git config advice.defaultBranchName false
  fi

  # Set up git identity inside the container
  run ddev exec -s claude git config user.name "Test User"
  assert_success

  run ddev exec -s claude git config user.email "test@example.com"
  assert_success

  # Create a test file
  run ddev exec -s claude bash -c 'echo "test content" > test-file.txt'
  assert_success

  # Add the file
  run ddev exec -s claude git add test-file.txt
  assert_success

  # Commit the file
  run ddev exec -s claude git commit -m "Test commit from claude container"
  assert_success
  [[ "$output" =~ "Test commit from claude container" ]]

  # Verify the commit was created with proper author info
  run ddev exec -s claude git log -1 --pretty=format:"%an <%ae>"
  assert_success
  [[ "$output" =~ "Test User <test@example.com>" ]]

  # Cleanup
  ddev exec -s claude rm -f test-file.txt || true
  ddev exec -s claude git reset --hard HEAD~1 2>/dev/null || true
}

@test "git commit uses host global config when available" {
  cd "$TESTDIR"

  # Skip if host doesn't have git configured globally
  host_name=$(git config --global user.name 2>/dev/null || echo "")
  host_email=$(git config --global user.email 2>/dev/null || echo "")
  if [ -z "$host_name" ] || [ -z "$host_email" ]; then
    skip "Host git not configured globally"
  fi

  # Check if git repo exists, if not initialize it
  run ddev exec -s claude test -d .git
  if [ "$status" -ne 0 ]; then
    run ddev exec -s claude git init
    assert_success
    run ddev exec -s claude git config advice.defaultBranchName false
  fi

  # Commit inside container WITHOUT setting repo-level config
  # Should use host global config via mounted ~/.gitconfig
  run ddev exec -s claude bash -c 'echo "test content 2" > test-file-2.txt'
  assert_success

  run ddev exec -s claude git add test-file-2.txt
  assert_success

  run ddev exec -s claude git commit -m "Test commit using host config"
  assert_success
  [[ "$output" =~ "Test commit using host config" ]]

  # Verify the commit used host identity
  run ddev exec -s claude git log -1 --pretty=format:"%an"
  assert_success
  [[ "$output" == "$host_name" ]]

  run ddev exec -s claude git log -1 --pretty=format:"%ae"
  assert_success
  [[ "$output" == "$host_email" ]]

  # Cleanup
  ddev exec -s claude rm -f test-file-2.txt || true
  ddev exec -s claude git reset --hard HEAD~1 2>/dev/null || true
}
