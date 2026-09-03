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
- App profiles in `config/apps/*.yml` describe app clones such as `sprung` and
  `flexday`.
- Worktree drivers select generic Git behavior, centrally stored app behavior,
  or a compatibility adapter from the app repository.

The top-level CLI handles host/app discovery, SSH, shared services, DNS, certs,
and dispatch. Central drivers are transmitted over SSH for each command, so the
execution host does not need a Tesseract checkout or installation.

## Command Shape

All commands accept `--host`. If omitted, `--host tars` is used, except plain
`live` and `pages list`, which aggregate results from all configured remote
hosts.

```bash
bin/tesseract doctor
bin/tesseract live
bin/tesseract bootstrap
bin/tesseract services up|down|logs
bin/tesseract app list
bin/tesseract app doctor|clone|pull|setup APP
bin/tesseract attach SESSION
bin/tesseract attach APP SLUG
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

Plain `pages list` reads `~/.obfuscated_pages.json` on every configured remote
host and adds a host column to the combined output. Pass `--host` to list only
the selected host. It prints registered pages newest first with their updated
date, title, and URL. Results are paginated independently per host with 10 rows
per page by default. Select a page with `--page N` and change its size with `--per-page N`.
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
bin/tesseract attach sprung patientnow-integration --host tars
bin/tesseract worktree status sprung patientnow-integration
bin/tesseract worktree start flexday calendar-refresh --host tars
```

## Prerequisites

- SSH access to the runtime user, for example `bot@tars`.
- SSH access to the service user, for example `achan@tars`.
- Tailscale on the machine used to open remote apps in a browser.
- Docker access for the service user, not the runtime user.
- `mise`, `git`, `ruby`, the configured session runtime (`tmux` or Herdr), and
  app-specific runtimes on the execution host. Herdr-backed adapters also
  require `jq`.
- A Cloudflare API token with `Zone:Read` and `DNS:Edit` for `achan.bot` when
  running DNS or certificate commands.

`bin/tesseract dns sync` and `bin/tesseract cert issue|renew` read
`CLOUDFLARE_API_TOKEN` from the local environment and pass only the needed value
to the remote command.

If the token is assigned in `~/.zshrc` without `export`, run DNS and cert
commands through zsh:

```bash
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract dns sync sprung --host tars'
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract cert issue sprung --host tars'
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
bin/tesseract app clone sprung --host tars
bin/tesseract app setup sprung --host tars

bin/tesseract app clone flexday --host tars
bin/tesseract app setup flexday --host tars

bin/tesseract app clone chrome-extensions --host tars

bin/tesseract app clone mobile-dashboard --host case

bin/tesseract app clone tesseract-web --host tars
bin/tesseract app setup tesseract-web --host tars
```

`app setup` uses the app repository runtime files through `mise`; no global
runtime activation is required.

Check an app profile and remote clone:

```bash
bin/tesseract app doctor sprung --host tars
```

Pull the selected app's main repo from `origin main`. This refuses to run when
the main repo has local changes:

```bash
bin/tesseract app pull sprung --host tars
```

## Shared App Environment

Each app profile points at a shared env file on the host:

```text
sprung: /home/bot/repos/sprung-app/.env.local
flexday: /home/bot/repos/flexday/.env.local
tesseract-web: /home/bot/repos/tesseract-web/.env.local
```

Worktree creation links, copies, or generates environment files according to
the selected worktree driver. Keep real env files out of git and set
permissions to `0600`.

## DNS and Certificates

Sync app DNS records to the host's Tailscale IP:

```bash
bin/tesseract dns sync sprung --host tars
bin/tesseract dns doctor sprung --host tars

bin/tesseract dns sync flexday --host tars
bin/tesseract dns doctor flexday --host tars
```

Issue or inspect app certificates:

```bash
bin/tesseract cert issue sprung --host tars
bin/tesseract cert doctor sprung --host tars
bin/tesseract cert renew sprung --host tars
```

Sprung uses one certificate covering the base and wildcard names for both
`docovia.tars.achan.bot` and `smilesnap.tars.achan.bot`. It remains installed
under the existing Docovia-derived paths so existing worktree symlinks remain valid:

```text
/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt
/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key
```

## Worktree Lifecycle

List worktrees with their runtime, attach target, and URL:

```bash
bin/tesseract worktree list --host tars
bin/tesseract worktree list sprung --host tars
```

Attach to a worktree by app and slug, regardless of its runtime:

```bash
bin/tesseract attach signatures general-dev --host tars
```

The legacy one-argument form remains available for direct tmux attachment:

```bash
bin/tesseract attach docovia_smoke_test --host tars
```

Create a worktree from the app repository default branch:

```bash
bin/tesseract worktree create sprung smoke-test --host tars
```

Create a worktree from a specific branch:

```bash
bin/tesseract worktree create sprung patientnow-integration origin/feature/patientnow-integration --host tars
```

Start, inspect, stop, and remove the worktree:

```bash
bin/tesseract worktree start sprung smoke-test --host tars
bin/tesseract worktree status sprung smoke-test --host tars
bin/tesseract worktree stop sprung smoke-test --host tars
bin/tesseract worktree remove sprung smoke-test --host tars
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

Sprung worktrees run in the default Herdr session. Starting one creates a
`spr/<slug>` workspace with a Code tab (Codex and terminal panes) and a Servers
tab (Rails, jobs, and webpack panes). Existing `doc/<slug>` workspaces are
renamed when started, while legacy `docovia_<slug>` tmux sessions are reported
by status and must be stopped before the worktree can start in Herdr.

`sprung` is the canonical CLI app id and the only one shown by `app list`.
`docovia` and `smilesnap` remain accepted aliases; they resolve to the same
repository, worktree paths, databases, ports, certificate, and runtime state.
The name used for `worktree start` selects the generated application environment:
`sprung` and `docovia` write the Docovia domains and
`docovia-development-public`, while `smilesnap` writes the SmileSnap domains and
`smilesnap-development-public`. Switching requires stopping the worktree first;
start refuses to rewrite these settings while its runtime is active.
Status and Herdr metadata use the Docovia URL as primary and status also reports
the SmileSnap URL as `url_alias[smilesnap.tars.achan.bot]`.

Mobile Dashboard uses the same Git-only lifecycle on `case`. The existing main
clone lives at `/Users/bot/repos/mobile-dashboard`, and worktrees are created
under `/Users/bot/repos/mobile-dashboard-worktrees`. Starting a worktree opens
a tmux session but does not install dependencies, launch Expo or Metro, or
assign a URL:

```bash
bin/tesseract worktree create mobile-dashboard cost-calculator --host case
bin/tesseract worktree start mobile-dashboard cost-calculator --host case
bin/tesseract worktree status mobile-dashboard cost-calculator --host case
bin/tesseract attach mobile_dashboard_cost_calculator --host case
```

Signatures uses the default Herdr session. Its workspace display label is the
shorthand app/worktree identity:

```text
sig/<slug>
```

The Codex pane's agent display label is simply:

```text
codex
```

Each Signatures workspace has two tabs. `Code` opens first with a vertical
split: Codex on the left and an interactive terminal on the right. `Servers`
is the second tab and runs `bin/dev` in its root pane.

The driver publishes the worktree's full HTTPS URL as `url` metadata on every
pane. Herdr's right-side tab status command reads that token instead of showing
the server hostname, so the same visible, link-detected URL remains available
while moving between Code, Terminal, and Servers.

Other configured apps still use tmux. `stop` closes the app's runtime and
processes but leaves the worktree, database, env files, and registry entry in
place. `remove` is destructive: it stops the runtime and removes the git
worktree. Signatures lifecycle behavior is owned by the central `signatures`
driver. Sprung uses the central `sprung` driver around its app-local lifecycle
adapter; compatibility profiles such as Flexday still delegate directly to an
app-local adapter.

`config/app-shorthands.yml` defines display names for Signatures (`sig`),
Sprung (`spr`), Docovia (`doc`), Smilesnap (`ss`), Flexday (`f`), Chrome Extensions (`cex`),
Tesseract Web (`tess`), and Mobile Dashboard (`md`). Only the central
Signatures and Sprung drivers consume their canonical names for Herdr today.

## Live Worktrees

Show currently running app worktrees, their URLs, and stable changelog URLs:

```bash
bin/tesseract live --host tars
```

Example output:

```text
RUNTIME  TARGET                           RSS URL                                      CHANGELOG
herdr    default:spr/patientnow-integration 512MiB https://app.docovia.tars.achan.bot:3102 https://pages-tars.achan.bot/p/<opaque-token>.html
herdr    default:sig/general-dev        2.4GiB https://signatures.achan.bot:6204       https://pages-tars.achan.bot/p/<opaque-token>.html
```

`live` scans each configured app's main clone, asks its selected driver for
each worktree status, and prints running runtime targets with their URLs. RSS is
the aggregate resident memory for processes whose current working directory is
the worktree path or one of its subdirectories. Changelog URLs use the stable
opaque token registered by the changelog publisher when present, with a
deterministic path-derived placeholder otherwise. A placeholder can return
`404` until its changelog is published.

## Browser Access

Open the URL reported by `worktree status` or `live`.

Sprung's primary Docovia URLs usually look like:

```text
https://app.docovia.tars.achan.bot:3101
https://api.docovia.tars.achan.bot:3101
```

The same worktree is also available through SmileSnap:

```text
https://app.smilesnap.tars.achan.bot:3101
https://api.smilesnap.tars.achan.bot:3101
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
bin/tesseract dns doctor sprung --host tars
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

Add its Herdr display shorthand to `config/app-shorthands.yml`. Until an app's
driver uses Herdr, this only prepares the shared definition and does not change
its runtime behavior.

Select a centrally stored driver with `worktree_driver`. Signatures uses the
`signatures` driver under `libexec/tesseract/worktree-drivers`; the CLI sends
that driver to the selected host when it runs. A `repository` profile is the
compatibility option for apps that still provide an executable
`bin/tesseract`.

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
to underscores; `stop` kills that session. By default, Git-only profiles do not
launch an app server, assign a URL, or run app-specific setup. They can opt into
an app server by defining `base_port`, `url_template`, and `processes.web`.
Tesseract then assigns each worktree a stable port, exports it as `PORT`,
launches the web command in tmux, reports the expanded URL from `status`, and
releases the assignment on removal.

## Resetting Runtime State

Use these only when intentionally deleting remote runtime state.

Remove a worktree:

```bash
bin/tesseract worktree stop sprung smoke-test --host tars || true
bin/tesseract worktree remove sprung smoke-test --host tars || true
```

Remove the Sprung main clone and tesseract metadata on `tars`:

```bash
ssh bot@tars 'rm -rf \
  /home/bot/repos/sprung-app \
  /home/bot/repos/sprung-worktrees \
  /home/bot/.local/share/tesseract/registry/sprung.tsv \
  /home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt \
  /home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key \
  /home/bot/.acme.sh/docovia.tars.achan.bot_ecc'
```

Reset shared PostgreSQL and Redis volumes:

```bash
ssh achan@tars 'cd /home/achan/.config/tesseract/services && docker compose -f compose.yml down -v'
```

Then start again from `Host Bootstrap`.
