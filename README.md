# ddev-claude

A DDEV addon that runs [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) in a sandboxed container with a whitelist-based network firewall. Run `--dangerously-skip-permissions` with confidence -- the firewall blocks all unauthorized outbound traffic, neutralizing prompt injection data exfiltration.

## About this fork

This fork ([marcoscano/ddev-claude](https://github.com/marcoscano/ddev-claude)) carries the following changes on top of [florianriquelme/ddev-claude](https://github.com/florianriquelme/ddev-claude), one commit each. Detailed write-ups with reproduction steps live in the linked upstream issues.

1. **PreToolUse hooks emit Claude Code-compatible JSON** -- the domain
   approval flow and secret protection were silent no-ops because the hooks
   used a JSON schema Claude Code does not recognize
   ([upstream #10](https://github.com/FlorianRiquelme/ddev-claude/issues/10)).
2. **Whitelist cache written world-readable** -- after the root watcher
   regenerated the mktemp (0600) cache, the non-root URL hook failed closed
   and denied every domain
   ([upstream #11](https://github.com/FlorianRiquelme/ddev-claude/issues/11)).
3. **add-domain updates reach the firewall watcher** -- mv-into-place emits
   no inotify event on DDEV mounts (the watcher never reloaded), and `set -e`
   aborted the domain loop on the expected non-root ipset failure
   ([upstream #12](https://github.com/FlorianRiquelme/ddev-claude/issues/12)).
4. **Secret-protection scripts shipped executable, caches readable** -- the
   secret cache could never be built ("Secret protection cache unavailable"),
   and an unreadable deny cache made the hook fail open
   ([upstream #13](https://github.com/FlorianRiquelme/ddev-claude/issues/13)).
5. **Periodic firewall whitelist refresh** -- ipset entries expire after
   3600s but were only re-resolved on config changes, so after 1h of uptime
   all egress silently dropped
   ([upstream #9](https://github.com/FlorianRiquelme/ddev-claude/issues/9)).
6. **Drush database access from the sandbox** -- `php-mysql` in the image,
   `IS_DDEV_PROJECT=true` in the environment, and the internal `db` service
   in the default whitelist, so `vendor/bin/drush` fully bootstraps against
   the DDEV database out of the box.
7. **Self-diagnosing database connection failures** -- a PostToolUse hook
   (`db-conn-check.sh`) detects MySQL/PostgreSQL connection errors in Bash
   tool output, probes whether the db container is reachable, and injects
   fix instructions into the agent context (whitelist the current db IP via
   `add-domain <ip>.sslip.io`). Without it, a stale firewall entry after a
   docker network change looks like a generic "database is down" error and
   agents troubleshoot the wrong layer.
8. **Drush site aliases work out of the box** -- four fixes in one commit:
   the image installs PHP matching the project's `php_version` via
   deb.sury.org (Debian bookworm only ships 8.2, which fails Composer's
   platform check on newer projects); the project is additionally mounted
   at `/var/www/html` (with the same `.env` masking) so aliases whose
   `root:` points at the web container's docroot resolve identically, and
   absolute paths baked into DB-shared caches stay consistent with the web
   container; `/var/www/html/vendor/bin` is appended to `PATH` so bare
   `drush` resolves; and `DDEV_PHP_VERSION` is exported so settings files
   detect in-container execution. Also repairs change 6: `db` now lives in
   `default-whitelist.json`, the file `merge-whitelist.sh` actually reads
   -- it had been added to `whitelist-domains.txt`, a vestigial file the
   firewall never consumes (now removed).
9. **Remote browser piloting via playwright-cli** -- the image ships a
   pinned `@playwright/cli` client (no browsers). A project can run a
   Playwright browser server inside its web container (a
   `chromium.launchServer()` script under `web_extra_daemons`) and
   whitelist `web`; the sandbox then drives that real browser with
   `playwright-cli attach --endpoint ws://web:<port>/<path>`. The browser
   keeps the web container's DNS/TLS context, no exec bridge into the web
   container is needed, and launch options stay pinned server-side
   (`launchServer()` rather than `run-server --unsafe`, which would let
   clients run arbitrary executables). Client and server must share the
   same playwright-core version -- upgrade them together.

To switch a project from upstream to this fork, remove the old install first
and delete anything left behind -- DDEV never removes or overwrites files
whose `#ddev-generated` marker was stripped (e.g. by hand-applied fixes), so
a clean slate avoids install warnings:

```bash
ddev add-on remove ddev-claude
rm -rf .ddev/claude .ddev/docker-compose.claude_refresh.yaml
ddev add-on get marcoscano/ddev-claude --version main
ddev restart
```

(`--version main` is needed until this fork publishes a release.)

## Why You Need This

Claude Code's `--dangerously-skip-permissions` flag unlocks autonomous mode: Claude can edit files, run commands, and install packages without asking. This is powerful but risky. A prompt injection hidden in a file Claude reads could instruct it to exfiltrate your code, secrets, or credentials to an attacker-controlled server.

This addon solves that. It runs Claude in a dedicated container with an iptables firewall that **defaults to DROP** -- only explicitly whitelisted domains are reachable. Even if Claude is tricked into making a malicious request, the firewall blocks it.

Your web container is completely unaffected.

## Requirements

- DDEV v1.24.10 or later
- Docker with `NET_ADMIN` capability support

## Installation

```bash
ddev add-on get marcoscano/ddev-claude --version main
ddev restart
```

The first build takes a few minutes (installs Node.js, PHP, Composer, Claude CLI, and firewall tools). Subsequent starts use the cached Docker image.

## Authentication

Claude Code requires authentication. Choose one method:

### OAuth (Recommended)

```bash
ddev exec -s claude claude login
```

Follow the prompts to complete the device code flow in your browser.

### API Key

Add `ANTHROPIC_API_KEY` to your project's `.ddev/.env` file:

```
ANTHROPIC_API_KEY=sk-ant-...
```

Then restart: `ddev restart`.

## Usage

### Basic

```bash
# Start Claude with firewall protection
ddev claude

# Pass any Claude CLI flags
ddev claude --help
```

> **Note:** `ddev claude` always enables `--dangerously-skip-permissions` automatically. The firewall makes this safe by blocking unauthorized outbound traffic. You do not need to pass the flag yourself.

### No-Firewall Mode

When you need unrestricted network access -- for example, during initial setup to discover which domains Claude needs -- use the `--no-firewall` flag:

```bash
ddev claude --no-firewall
```

This does three things:

1. Disables the iptables firewall for the session
2. Runs tcpdump in the background to capture all DNS queries
3. After the session ends, prints every domain Claude accessed

The output looks like this:

```
[ddev-claude] Domains accessed during this session:
api.anthropic.com
registry.npmjs.org
some-new-service.example.com

[ddev-claude] Run 'ddev claude:whitelist' to add these to your whitelist
```

Use this to build your whitelist, then switch back to the firewalled mode.

### Whitelist Manager

```bash
ddev claude:whitelist
```

The interactive whitelist manager:

1. Scans the firewall log for blocked domains
2. Reads domains captured during `--no-firewall` sessions
3. Presents a combined, deduplicated list
4. Lets you select which domains to whitelist (space to toggle, enter to confirm)
5. Asks whether to save to global or per-project config
6. Hot reload applies the changes within 2-3 seconds -- no restart needed

### Automatic Domain Approval

When Claude tries to access a domain that is not whitelisted, the addon intercepts the request before it executes:

1. A **PreToolUse hook** inspects every tool call (WebFetch, Bash commands containing URLs, MCP tool inputs) and checks extracted domains against the current whitelist
2. If the domain is not whitelisted, the hook **denies the tool call** and tells Claude which domain was blocked
3. Claude sees the denial and asks you in plain language whether you want to whitelist the domain
4. If you approve, Claude runs `/opt/ddev-claude/bin/add-domain <domain>`, which immediately updates the whitelist JSON and the live firewall rules
5. Claude retries the original request and succeeds

This gives you a conversational approval flow without leaving the CLI. The hook is a UX layer -- the kernel-level iptables firewall remains the security foundation. Even if the hook were bypassed, the firewall would still DROP unauthorized traffic.

## Configuration

### Whitelist Hierarchy

The addon merges whitelists from three sources (all optional except the default):

| Priority | File | Scope |
|----------|------|-------|
| 1 | `.ddev/claude/config/default-whitelist.json` | Ships with addon. Do not edit -- overwritten on upgrade. |
| 2 | `~/.ddev/ddev-claude/whitelist.json` | Global. Applies to all your DDEV projects. |
| 3 | `.ddev/ddev-claude/whitelist.json` | Per-project. Commit to your repo or gitignore, your choice. |

All three are JSON arrays of domain strings:

```json
["api.example.com", "cdn.example.com"]
```

Domains are merged and deduplicated automatically. The merged result is resolved to IPs via `dig` and added to an ipset.

### Hot Reload

You do not need to restart DDEV after editing a whitelist file. An inotify watcher detects changes to any `whitelist.json` and reloads the firewall within 2-3 seconds. The watcher validates JSON before applying -- a malformed file is ignored and the previous whitelist stays active.

### Default Whitelisted Domains

The addon ships with these domains pre-whitelisted in `default-whitelist.json`:

**Claude API:**
- `api.anthropic.com`
- `claude.ai`
- `statsig.anthropic.com`
- `sentry.io`

**GitHub:**
- `github.com`
- `api.github.com`
- `raw.githubusercontent.com`
- `objects.githubusercontent.com`
- `codeload.github.com`

**Package registries:**
- `registry.npmjs.org`
- `packagist.org`
- `repo.packagist.org`

**CDNs:**
- `cdn.jsdelivr.net`
- `unpkg.com`

### Stack Templates

Reference templates are available in `.ddev/claude/config/stack-templates/`:

- `npm.json` -- adds `registry.npmjs.org`, `registry.yarnpkg.com`, GitHub
- `laravel.json` -- adds `packagist.org`, `repo.packagist.org`, `raw.githubusercontent.com`, GitHub

Use these as a starting point when building your own whitelist files.

## MCP Servers

### What Works

HTTP-based MCP servers that connect to external URLs work automatically **if their domain is whitelisted**. The addon auto-detects MCP server URLs from three config files on container start:

- `~/.mcp.json` (global MCP config)
- `~/.claude.json` (Claude Code config, both global and per-project `mcpServers`)
- `.mcp.json` (project-local MCP config)

Detected domains are resolved and added to the firewall whitelist alongside your configured domains. No manual whitelisting needed for MCP servers that are already in your config files.

### What Does Not Work

- **Stdio MCP servers on your host machine** -- The container's `localhost` is not your host's `localhost`. Servers like filesystem, git, or other stdio-based tools running on your host are not reachable from inside the container.
- **OAuth-based MCP servers** -- These require a browser-based authentication flow, which is not possible inside a headless container.

### Common Issue: "Needs Authentication" Errors

If an MCP server reports authentication errors, the cause is almost always a firewall block, not an actual auth problem. The server cannot reach its API endpoint because the domain is not whitelisted. Add the domain to your whitelist and the error will resolve.

## Pitfalls and Troubleshooting

### Git says "Author identity unknown"

`ddev claude` runs Git inside the `claude` container. This addon bind-mounts your host Git global config (`~/.gitconfig` and `~/.config/git`) into that container, so globally configured `user.name` and `user.email` are available automatically.

If you still see identity errors, verify on host:

```bash
git config --global user.name
git config --global user.email
```

Then restart the addon container to refresh mounts:

```bash
ddev restart
```

### "Connection refused" or "needs authentication" from MCP servers

This is usually a firewall block, not an auth issue. The server's outbound HTTP request is being dropped. Add the target domain to your whitelist (global or per-project) and the hot reload will apply it within seconds.

### Domain was whitelisted but still blocked

The addon resolves domains to IP addresses via `dig` at startup and on config reload. If a service uses CDN rotation or returns different IPs over time, the resolved IP may no longer match. Run `ddev restart` to force a full re-resolution of all domains.

### IPv4 only

The firewall manages IPv4 traffic only. IPv6 traffic is not filtered. In practice this is not a problem -- most services resolve to IPv4 addresses in the container environment.

### ipset entries expire after 1 hour

Whitelisted IPs are added with a 3600-second timeout in ipset. The hot-reload watcher refreshes entries on config changes, and the healthcheck monitors ipset state every 30 seconds. In very long idle sessions without config changes, entries may expire. Edit and save any whitelist file (even without changes) to trigger a refresh, or run `ddev restart`.

### Container restart resets firewall state

All iptables rules and ipset entries are rebuilt from config files on every container start. Manual changes to iptables inside the container do not persist across `ddev restart`.

### `--no-firewall` relies on DNS traffic

The tcpdump capture monitors all traffic on port 53 (queries and responses). In rare cases where DNS results are cached, some domains may not appear in the session log. Run `ddev claude:whitelist` to also check the firewall's blocked-request log for any domains that were missed.

### Localhost MCP servers do not work

The container has its own network namespace. `localhost` inside the container refers to the container itself, not your host machine. Host-based stdio MCP servers (filesystem, git, etc.) are not reachable. This is a fundamental limitation of container isolation.

### `ddev` commands inside claude container

The claude container includes a `ddev` shim that enables Claude to run runtime commands directly while blocking lifecycle commands. This provides convenience without compromising security:

**Runtime commands are auto-forwarded:**
```bash
# Inside claude container, these work automatically:
ddev php --version         # → executes: php --version
ddev composer install      # → executes: composer install
ddev npm run build         # → executes: npm run build
ddev node script.js        # → executes: node script.js
```

Claude can run `php`, `composer`, `node`, and `npm` commands without user intervention. Unknown commands are attempted directly -- if the command doesn't exist, you'll see a standard "command not found" error.

**Lifecycle commands are blocked:**
```bash
# These exit 127 with helpful error messages:
ddev restart               # → "Must run on host: ddev restart"
ddev exec -s web php -v    # → "Must run on host: ddev exec -s web php -v"
ddev start                 # → "Must run on host: ddev start"
```

Lifecycle commands (`start`, `restart`, `stop`, `exec`, `config`, etc.) must run on the host. The shim prevents confusion and suggests the correct command to run.

### First build is slow

The Dockerfile installs Node.js (LTS), PHP, Composer, Claude CLI, gum, iptables, ipset, and other tools. This is a one-time cost -- subsequent `ddev restart` commands use the cached Docker image.

### Web container is unchanged

This addon creates a separate `claude` container. Your web container's network, packages, and configuration are completely unaffected. You can remove the addon at any time with no side effects on your project.

### Hooks only detect explicit URLs

The PreToolUse hook extracts URLs from tool calls -- WebFetch URLs, URLs in Bash commands, URLs in MCP tool inputs. It does not detect implicit network access from commands like `npm install` or `composer require` that do not contain URLs. For those, the iptables firewall still blocks unauthorized traffic and the blocked-request log captures the attempt. Use `ddev claude:whitelist` to whitelist domains from the blocked log.

### Firewall fails closed

If firewall initialization fails for any reason -- DNS issues, iptables errors, missing config files -- the entrypoint blocks ALL outbound traffic and exits with an error. This is by design. The system fails safe rather than failing open.

## Debugging the Firewall

```bash
# Show current iptables rules
ddev exec -s claude iptables -L OUTPUT -n

# Show all whitelisted IPs in the ipset
ddev exec -s claude ipset list whitelist_ips

# View blocked request log
ddev exec -s claude cat /tmp/ddev-claude-blocked.log

# Check container health status
docker inspect --format='{{.State.Health.Status}}' ddev-$(basename $PWD)-claude
```

The healthcheck runs every 30 seconds and validates:

1. iptables rules are loaded
2. OUTPUT policy is DROP
3. The `whitelist_ips` ipset exists (warns if empty, but does not fail)
4. Non-whitelisted traffic is actively blocked (tested against a reserved IP range)

## Architecture

```
+---------------------------------------------------------------+
|                        DDEV Project                           |
+---------------------------+-----------------------------------+
|     web container         |         claude container          |
|     (unchanged)           |                                   |
|                           |   +---------------------------+   |
|                           |   |    iptables firewall      |   |
|                           |   |    (OUTPUT chain)         |   |
|                           |   |                           |   |
|                           |   |  1. ACCEPT loopback       |   |
|                           |   |  2. ACCEPT DNS (port 53)  |   |
|                           |   |  3. ACCEPT established    |   |
|                           |   |  4. ACCEPT ipset match    |   |
|                           |   |  5. LOG blocked           |   |
|                           |   |  6. policy DROP           |   |
|                           |   +---------------------------+   |
|                           |                                   |
|                           |   Claude CLI + PHP + Node.js      |
|                           |   Composer + git + curl           |
+---------------------------+-----------------------------------+
|                    ddev_default network                        |
+---------------------------------------------------------------+

Mounts:
  ${DDEV_APPROOT}  -->  ${DDEV_APPROOT}            (project files, real host path)
  .ddev/claude/config/empty.env --> ${DDEV_APPROOT}/.env        (masked)
                               --> ${DDEV_APPROOT}/.ddev/.env   (masked)
  ~/.claude/       -->  /root/.claude/              (persistent sessions)
                   -->  /home/claude/.claude/
                   -->  ${HOME}/.claude/            (host-absolute plugin paths)
  ~/.claude.json   -->  /root/.claude.json          (Claude config + MCP servers)
                   -->  /home/claude/.claude.json
```

**Key design decisions:**

- **Dedicated container** -- Isolates Claude from the web container. The web container needs unrestricted network for normal operations; Claude's restrictions should never interfere.
- **debian:bookworm-slim base** -- Minimal footprint with access to standard Debian packages for PHP, Node.js, and firewall tools.
- **Real host path mount** -- The project is mounted at `${DDEV_APPROOT}` (the actual path on your host), not at `/var/www/html`. This ensures Claude's file references match your local paths.
- **Masked env files** -- `${DDEV_APPROOT}/.env` and `${DDEV_APPROOT}/.ddev/.env` are replaced in the claude container with `.ddev/claude/config/empty.env`. This prevents Claude from accessing project secrets.
- **ddev shim in claude** -- The `ddev` shim auto-forwards runtime commands (`php`, `composer`, `node`, `npm`) to the local runtime while blocking lifecycle commands (`start`, `restart`, `exec`). This lets Claude run development commands directly without compromising container isolation.
- **ipset for IP management** -- Efficient O(1) lookups for whitelisted IPs, with built-in timeout support for automatic expiry and refresh.
- **Fail-closed error handling** -- The entrypoint uses `trap ... ERR` to block all traffic if any setup step fails.
- **Claude Code hooks** -- PreToolUse hooks intercept tool calls before execution, check domains against the whitelist, and guide users through approval. The hooks are a UX improvement; iptables remains the security enforcement layer.
- **Healthcheck every 30s** -- Validates firewall state continuously. If the healthcheck fails, Docker marks the container as unhealthy.

## Removing the Addon

```bash
ddev addon remove ddev-claude
ddev restart
```

This removes all addon files from `.ddev/` and stops the claude container. The addon's PreToolUse hooks are removed from `.claude/settings.local.json` and `~/.claude/settings.json`. Your project and web container are not affected.

## Testing

The addon is covered by a Bats test suite across hooks, host commands, core scripts, and script syntax.

```bash
./tests/run-bats.sh
```

If `bats` is missing, install `bats-core` and rerun the command.
## Contributing

Contributions are welcome. Please open an issue or pull request on [GitHub](https://github.com/florianriquelme/ddev-claude).

## License

MIT

---

**Maintained by:** [Florian Riquelme](https://friquelme.dev) ([GitHub](https://github.com/florianriquelme))
