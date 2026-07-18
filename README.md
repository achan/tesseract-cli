# tesseract-cli

Personal development control plane for running app worktrees, dev servers, and
coding agents on remote hosts.

The default host is `tars`. Runtime work runs as `bot`; Docker-backed shared
services run as `achan` through the host profile's `service_user`.

## Mental Model

`bin/tesseract` is run from this repo on the control machine, usually the
MacBook. It reads local YAML profiles, connects to the selected host over SSH,
and runs the requested operation there.

There are three layers:

- Host profiles in `config/hosts/*.yml` describe machines such as `tars` and
  `local`.
- App profiles in `config/apps/*.yml` describe app clones such as `docovia` and
  `flexday`.
- Repo-local app adapters, usually `<app main path>/bin/tesseract`, own
  app-specific worktree behavior.

The top-level CLI handles host/app discovery, SSH, shared services, DNS, certs,
and dispatch. Worktree commands intentionally delegate into the app repository
so each app can decide how to create databases, env files, tmux sessions,
servers, workers, and asset processes.

## Command Shape

All commands accept `--host`. If omitted, `--host tars` is used.

```bash
bin/tesseract doctor
bin/tesseract live
bin/tesseract bootstrap
bin/tesseract services up|down|logs
bin/tesseract app list
bin/tesseract app doctor|clone|pull|setup APP
bin/tesseract attach SESSION
bin/tesseract worktree list [APP]
bin/tesseract worktree create|start|stop|status|remove APP SLUG [BRANCH]
bin/tesseract dns doctor|sync APP
bin/tesseract cert doctor|issue|renew APP
bin/tesseract pages list [--sort updated|title|url] [--page N] [--per-page N]
bin/tesseract pages start|status|stop
```

## Public HTML Pages

Serve the selected host's pages directory publicly through its configured
Cloudflare Tunnel, with Tailscale Funnel as the fallback for hosts without a
custom pages domain:

```bash
bin/tesseract pages list --host tars
bin/tesseract pages list --sort title --host tars
bin/tesseract pages list --page 2 --host tars
bin/tesseract pages start --host tars
bin/tesseract pages status --host tars
bin/tesseract pages stop --host tars
```

`pages list` reads `~/.obfuscated_pages.json` as the selected host's runtime
user (`bot` on `tars`) and prints registered pages newest first with their
updated date, title, and URL. Results are paginated with 10 rows per page by
default. Select a page with `--page N` and change its size with `--per-page N`.
Dates use `YY/MM/DD`. Output uses 100-character columns; long titles are
truncated, while URLs remain complete and may extend past that width. Sort with
`--sort updated|title|url`; updated is the default and sorts newest first, while
title and URL sort ascending. Missing registries return `none`.

On `tars`, place HTML and related assets in `/home/bot/pages`. The command runs
a loopback-only Python static server in tmux and exposes it at
`https://pages-tars.achan.bot/` through Cloudflare Tunnel. The directory is
publicly reachable; do not place private files in it.

The pages server returns an `X-Robots-Tag` no-index header on every response and
publishes a root `robots.txt` that disallows all crawling. Recognized search and
AI crawler user agents are also rejected with `403`. These controls are not a
substitute for authentication because clients can misrepresent their user agent.

Examples:

```bash
bin/tesseract app list
bin/tesseract live
bin/tesseract worktree list
bin/tesseract attach docovia_patientnow_integration --host tars
bin/tesseract worktree status docovia patientnow-integration
bin/tesseract worktree start flexday calendar-refresh --host tars
```

## Prerequisites

- SSH access to the runtime user, for example `bot@tars`.
- SSH access to the service user, for example `achan@tars`.
- Tailscale on the machine used to open remote apps in a browser.
- Docker access for the service user, not the runtime user.
- `mise`, `git`, `tmux`, `ruby`, and app-specific runtimes on the execution
  host.
- A Cloudflare API token with `Zone:Read` and `DNS:Edit` for `achan.bot` when
  running DNS or certificate commands.

`bin/tesseract dns sync` and `bin/tesseract cert issue|renew` read
`CLOUDFLARE_API_TOKEN` from the local environment and pass only the needed value
to the remote command.

If the token is assigned in `~/.zshrc` without `export`, run DNS and cert
commands through zsh:

```bash
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract dns sync docovia --host tars'
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract cert issue docovia --host tars'
```

## Host Bootstrap

Bootstrap creates runtime directories for the selected host and writes the
shared Docker Compose file for PostgreSQL and Redis.

```bash
bin/tesseract doctor --host tars
bin/tesseract bootstrap --host tars
bin/tesseract services up --host tars
bin/tesseract services logs --host tars
```

For a new macOS execution host such as `case.local`, first create the runtime
user and authorize this control machine's SSH key on the Mac itself:

```bash
mkdir -p ~/.ssh
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIfNnZk/K9XXbP7y7oWoPVZmCdBzBu3JTOj8/FQfhe2J ac@amoschan.com' >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys

sudo sysadminctl -addUser bot -fullName "Tesseract Bot" -home /Users/bot -shell /bin/zsh -password 'CHANGE-ME'
sudo mkdir -p /Users/bot/.ssh /Users/bot/repos
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIfNnZk/K9XXbP7y7oWoPVZmCdBzBu3JTOj8/FQfhe2J ac@amoschan.com' | sudo tee -a /Users/bot/.ssh/authorized_keys >/dev/null
sudo chown -R bot:staff /Users/bot/.ssh /Users/bot/repos
sudo chmod 700 /Users/bot/.ssh
sudo chmod 600 /Users/bot/.ssh/authorized_keys
```

Then verify and bootstrap it from the control machine:

```bash
bin/tesseract doctor --host case
bin/tesseract bootstrap --host case
```

On `tars`, the shared services are defined at:

```text
/home/achan/.config/tesseract/services/compose.yml
```

The runtime registry and cert directories are:

```text
/home/bot/.local/share/tesseract/registry
/home/bot/.local/share/tesseract/certs
```

## App Setup

List configured apps:

```bash
bin/tesseract app list
```

Clone and prepare an app on the selected host:

```bash
bin/tesseract app clone docovia --host tars
bin/tesseract app setup docovia --host tars

bin/tesseract app clone flexday --host tars
bin/tesseract app setup flexday --host tars

bin/tesseract app clone chrome-extensions --host tars

bin/tesseract app clone tesseract-web --host tars
bin/tesseract app setup tesseract-web --host tars
```

`app setup` uses the app repository runtime files through `mise`; no global
runtime activation is required.

Check an app profile and remote clone:

```bash
bin/tesseract app doctor docovia --host tars
```

Pull the selected app's main repo from `origin main`. This refuses to run when
the main repo has local changes:

```bash
bin/tesseract app pull docovia --host tars
```

## Shared App Environment

Each app profile points at a shared env file on the host:

```text
docovia: /home/bot/repos/sprung-app/.env.local
flexday: /home/bot/repos/flexday/.env.local
tesseract-web: /home/bot/repos/tesseract-web/.env.local
```

Worktree creation links or copies from the app's shared env according to the
repo-local adapter. Keep real env files out of git and set permissions to
`0600`.

## DNS and Certificates

Sync app DNS records to the host's Tailscale IP:

```bash
bin/tesseract dns sync docovia --host tars
bin/tesseract dns doctor docovia --host tars

bin/tesseract dns sync flexday --host tars
bin/tesseract dns doctor flexday --host tars
```

Issue or inspect app certificates:

```bash
bin/tesseract cert issue docovia --host tars
bin/tesseract cert doctor docovia --host tars
bin/tesseract cert renew docovia --host tars
```

Certificates are installed under the host cert directory. For Docovia on `tars`:

```text
/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt
/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key
```

## Worktree Lifecycle

List worktrees with their tmux session names and URLs:

```bash
bin/tesseract worktree list --host tars
bin/tesseract worktree list docovia --host tars
```

Attach to a worktree's tmux session:

```bash
bin/tesseract attach docovia_smoke_test --host tars
```

Create a worktree from the app repository default branch:

```bash
bin/tesseract worktree create docovia smoke-test --host tars
```

Create a worktree from a specific branch:

```bash
bin/tesseract worktree create docovia patientnow-integration origin/feature/patientnow-integration --host tars
```

Start, inspect, stop, and remove the worktree:

```bash
bin/tesseract worktree start docovia smoke-test --host tars
bin/tesseract worktree status docovia smoke-test --host tars
bin/tesseract worktree stop docovia smoke-test --host tars
bin/tesseract worktree remove docovia smoke-test --host tars
```

Tesseract web worktrees use the same lifecycle with the `tesseract-web` app id:

```bash
bin/tesseract worktree create tesseract-web ingestion-ui --host tars
bin/tesseract worktree start tesseract-web ingestion-ui --host tars
bin/tesseract worktree status tesseract-web ingestion-ui --host tars
```

Docovia Chrome Extensions uses the Git-only lifecycle with the
`chrome-extensions` app id. Starting it opens a tmux session rooted in the
worktree; it does not launch a web server or assign a URL:

```bash
bin/tesseract worktree create chrome-extensions manifest-v3 --host tars
bin/tesseract worktree start chrome-extensions manifest-v3 --host tars
bin/tesseract worktree status chrome-extensions manifest-v3 --host tars
```

`stop` kills the app's tmux session and processes but leaves the worktree,
database, env files, and registry entry in place. `remove` is destructive: it
stops the session, removes the git worktree, prunes registry metadata, and lets
the repo-local adapter clean up app-specific state.

Worktree commands run this shape on the selected host:

```bash
cd <app main path>
exec ./bin/tesseract worktree <action> <slug> [branch]
```

That app-local handoff is why Docovia and Flexday can share the top-level
control plane while keeping different runtime details.

## Live Worktrees

Show currently running app worktrees, their URLs, and stable changelog URLs:

```bash
bin/tesseract live --host tars
```

Example output:

```text
TMUX                              RSS URL                                              CHANGELOG
docovia_patientnow_integration 512MiB https://app.docovia.tars.achan.bot:3102          https://pages-tars.achan.bot/p/<opaque-token>.html
docovia_api_v2_foundation      1.4GiB https://app.docovia.tars.achan.bot:3104          https://pages-tars.achan.bot/p/<opaque-token>.html
```

`live` scans each configured app's main clone, asks the repo-local adapter for
each worktree status, and prints running tmux sessions with their URLs. RSS is
the aggregate resident memory for processes whose current working directory is
the worktree path or one of its subdirectories. Changelog URLs use the stable
opaque token registered by the changelog publisher when present, with a
deterministic path-derived placeholder otherwise. A placeholder can return
`404` until its changelog is published.

## Browser Access

Open the URL reported by `worktree status` or `live`.

Docovia URLs usually look like:

```text
https://app.docovia.tars.achan.bot:3101
https://api.docovia.tars.achan.bot:3101
```

Flexday URLs usually look like:

```text
http://flexday.tars.achan.bot:4001
```

Tesseract web URLs use the reserved `6101-6199` development range:

```text
https://tesseract-web.tars.achan.bot:6101
```

If the browser reports `ERR_NAME_NOT_RESOLVED`, verify DNS first:

```bash
bin/tesseract dns doctor docovia --host tars
```

Some local resolvers cache earlier NXDOMAIN responses. Use a resolver such as
`1.1.1.1`, wait for cache expiry, or temporarily add host entries for the
Tailscale IP.

## Adding an App

Add a YAML file under `config/apps/` with at least:

```yaml
id: example
repo: git@github.com:owner/repo
main_path: /home/bot/repos/example
domain: example.tars.achan.bot
env_shared_path: /home/bot/repos/example/.env.local
```

The app repository must provide an executable `bin/tesseract` when it wants to
support worktree lifecycle commands through this control plane.

For an early-stage repository that only needs Git worktrees, configure the
central Git-only driver instead:

```yaml
id: example
repo: git@github.com:owner/example.git
main_path: /home/bot/repos/example
worktree_root: /home/bot/repos/example-worktrees
worktree_driver: git
default_branch: main
domain: example.tars.achan.bot
database: false
dns_records: []
```

Git-only profiles support `worktree create`, `start`, `list`, `status`, `stop`,
and `remove`.
When no branch is supplied, `create` uses `feature/<slug>`. Existing local or
remote branches are reused; otherwise the branch is created from
`default_branch`. The `start` action opens a tmux session rooted in the
worktree using the conventional `<app>_<slug>` name, with hyphens converted
to underscores; `stop` kills that session. Git-only profiles do not launch an
app server, assign a URL, or run app-specific setup.

## Resetting Runtime State

Use these only when intentionally deleting remote runtime state.

Remove a worktree:

```bash
bin/tesseract worktree stop docovia smoke-test --host tars || true
bin/tesseract worktree remove docovia smoke-test --host tars || true
```

Remove the Docovia main clone and tesseract metadata on `tars`:

```bash
ssh bot@tars 'rm -rf \
  /home/bot/repos/sprung-app \
  /home/bot/repos/sprung-worktrees \
  /home/bot/.local/share/tesseract/registry/docovia.tsv \
  /home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt \
  /home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key \
  /home/bot/.acme.sh/docovia.tars.achan.bot_ecc'
```

Reset shared PostgreSQL and Redis volumes:

```bash
ssh achan@tars 'cd /home/achan/.config/tesseract/services && docker compose -f compose.yml down -v'
```

Then start again from `Host Bootstrap`.
