# tesseract-cli

Personal development control plane for running Docovia Rails worktrees and
coding agents on remote hosts.

The default host is `tars`. Runtime work runs as `bot`; Docker-backed shared
services run as `achan` through the host profile's `service_user`.

## Prerequisites

- SSH access to `bot@tars` and `achan@tars`.
- Tailscale on the machine used to open the app.
- A Cloudflare API token with `Zone:Read` and `DNS:Edit` for `achan.bot`.
  `bin/tesseract dns sync` and `bin/tesseract cert issue` read it from
  `CLOUDFLARE_API_TOKEN`.

If the token is assigned in `~/.zshrc` without `export`, run DNS and cert commands
through zsh:

```bash
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract dns sync docovia --host tars'
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract dns sync flexday --host tars'
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract cert issue docovia --host tars'
```

## Bootstrap

Create host directories, write the shared services compose file, and start
Postgres/Redis:

```bash
bin/tesseract bootstrap --host tars
bin/tesseract services up --host tars
bin/tesseract dns sync docovia --host tars
bin/tesseract dns sync flexday --host tars
bin/tesseract dns doctor docovia --host tars
bin/tesseract dns doctor flexday --host tars
```

`dns doctor` should show `host_tailscale_ip=100.101.231.49`. Some resolvers on
`tars` may still show empty `domain_a` values even when Cloudflare is already
authoritative.

## Certificates

Issue a Let's Encrypt certificate with ACME DNS-01 through Cloudflare:

```bash
zsh -lc 'source ~/.zshrc; export CLOUDFLARE_API_TOKEN; bin/tesseract cert issue docovia --host tars'
bin/tesseract cert doctor docovia --host tars
```

The installed certificate files are:

```text
/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt
/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key
```

The certificate covers:

```text
docovia.tars.achan.bot
*.docovia.tars.achan.bot
```

## Clone Docovia

```bash
bin/tesseract app clone docovia --host tars
bin/tesseract app setup docovia --host tars
```

## Clone Flexday

Flexday is also managed as an offloaded project on `tars`.

```bash
bin/tesseract app clone flexday --host tars
```

Seed the shared Flexday env file once from the existing `subot` checkout. This
is an operator step, not part of the tesseract scripts:

```bash
scp /Users/achan-bot/repos/flexday/.env.local bot@tars:/home/bot/repos/flexday/.env.local
ssh bot@tars 'chmod 0600 /home/bot/repos/flexday/.env.local'
```

Then install the configured Node/pnpm runtime and dependencies:

```bash
bin/tesseract app setup flexday --host tars
```

## Shared App Environment

Docovia expects a shared app env file at:

```text
/home/bot/repos/sprung-app/.env.local
```

`worktree create` links that file into each worktree when it already exists.
A full real env is preferred. For a minimal bootable development env:

```bash
ssh bot@tars 'cat > /home/bot/repos/sprung-app/.env.local <<EOF
APP_NAME=Docovia
VARIABLE_NAME=docovia
APP_DOMAIN=docovia.tars.achan.bot
DASHBOARD_DOMAIN=app.docovia.tars.achan.bot
APP_SUBDOMAIN=app
API_SUBDOMAIN=api
APP_PORT=:3101
PORT=3101
WEBSITE_URL=https://app.docovia.tars.achan.bot:3101
API_URL=https://api.docovia.tars.achan.bot:3101
WEBSITE_ROOT=app.docovia.tars.achan.bot:3101
CLIENT_URL=http://localhost:3050
PLATFORM_URL=https://www.docovia.com
EMAIL_DOMAIN=docovia.com
INTERNAL_ACCOUNT_ARRAY=[1]
INTERNAL_EMAILS=["@sprung.io", "@docovia.com"]
PARTNER_DOMAINS=[]
SALES_TEAM=["Amos"]
SMILEBRANDS_ACCOUNT_ID=0
UPLOAD_REFACTORED_ID=1
FACEBOOK_APP_ID=REPLACEME
APPLE_ITUNES_APP_ID=REPLACEME
GOOGLE_API_KEY_MAPS=REPLACEME
GOOGLE_API_KEY_GEOCODER=REPLACEME
TIMEZONE_API_KEY=REPLACEME
S3_BUCKET_NAME=docovia-development
S3_BUCKET_NAME_PUBLIC=docovia-development
SLACK_WEBHOOK=REPLACEME
SLACK_USER_WEBHOOK=REPLACEME
DATADOG_RUM_ENABLED=false
DATADOG_APPLICATION_ID=REPLACEME
DATADOG_CLIENT_TOKEN=REPLACEME
OPERATOR_NETWORK_DAYS_OFF=
EOF
chmod 0600 /home/bot/repos/sprung-app/.env.local'
```

## Worktrees

Create Docovia and Flexday worktrees with the same command shape:

```bash
bin/tesseract worktree create docovia smoke-test --host tars
bin/tesseract worktree create flexday smoke-test --host tars
```

Prepare the app dependencies and database:

```bash
ssh bot@tars 'set -eu
cd /home/bot/repos/sprung-worktrees/smoke-test
MISE="mise exec ruby@$(cat .ruby-version) node@$(cat .nvmrc) --"
$MISE bundle install
$MISE npm install -g yarn@1.22.22
$MISE yarn install --frozen-lockfile
perl -0pi -e "s/host: <%= ENV\\[\\\"DASHBOARD_DOMAIN\\\"\\] %>/host: 0.0.0.0/; s/public: <%= ENV\\[\\\"DASHBOARD_DOMAIN\\\"\\] %>:3035/public: app.docovia.tars.achan.bot:3035/" config/webpacker.yml
$MISE bundle exec rails db:migrate'
```

The Webpacker patch is currently required because this app's
`config/webpacker.yml` treats the ERB host value literally in this runtime.

Start the worktree:

```bash
bin/tesseract worktree start docovia smoke-test --host tars
bin/tesseract worktree status docovia smoke-test --host tars

bin/tesseract worktree start flexday smoke-test --host tars
bin/tesseract worktree status flexday smoke-test --host tars
```

Expected service panes:

```text
docovia_smoke_test:services.0 cmd=puma
docovia_smoke_test:services.1 cmd=ruby
docovia_smoke_test:services.2 cmd=node
```

Check panes with:

```bash
ssh bot@tars 'tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index} cmd=#{pane_current_command}"'
```

## Access

Open:

```text
https://app.docovia.tars.achan.bot:3101
http://flexday.tars.achan.bot:4001
```

Verify from the control machine:

```bash
curl -I --resolve app.docovia.tars.achan.bot:3101:100.101.231.49 \
  https://app.docovia.tars.achan.bot:3101
```

Expected response:

```text
HTTP/1.1 301 Moved Permanently
location: https://app.docovia.tars.achan.bot:3101/providers/login
```

If the browser reports `ERR_NAME_NOT_RESOLVED`, the local resolver may have
cached an earlier NXDOMAIN. Use a resolver such as `1.1.1.1`, wait for the cache
to expire, or add a temporary `/etc/hosts` entry:

```bash
sudo sh -c 'echo "100.101.231.49 app.docovia.tars.achan.bot api.docovia.tars.achan.bot gfease.docovia.tars.achan.bot docovia.tars.achan.bot" >> /etc/hosts'
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

## Reset Docovia

Use this only when intentionally deleting the remote Docovia runtime state.

```bash
bin/tesseract worktree stop docovia smoke-test --host tars || true
bin/tesseract worktree remove docovia smoke-test --host tars || true

ssh bot@tars 'rm -rf \
  /home/bot/repos/sprung-app \
  /home/bot/repos/sprung-worktrees \
  /home/bot/.local/share/tesseract/registry/docovia.tsv \
  /home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt \
  /home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key \
  /home/bot/.acme.sh/docovia.tars.achan.bot_ecc'
```

Reset shared Postgres/Redis volumes:

```bash
ssh achan@tars 'cd /home/achan/.config/tesseract/services && docker compose -f compose.yml down -v'
```

Then start again from `Bootstrap`.
