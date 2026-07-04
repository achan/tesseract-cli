require "tesseract/config"
require "tesseract/local_runner"
require "tesseract/remote_runner"
require "tesseract/shell"

module Tesseract
  class CLI
    DEFAULT_HOST = "tars"

    def initialize(argv, stdout: $stdout, stderr: $stderr, root: Config.default_root)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @config = Config.new(root)
      @host_id = DEFAULT_HOST
    end

    def run
      parse_global_options

      command = @argv.shift
      return usage("missing command") unless command

      case command
      when "doctor"
        doctor
      when "bootstrap"
        bootstrap
      when "services"
        services
      when "app"
        app
      when "worktree"
        worktree
      when "dns"
        dns
      when "cert"
        cert
      when "help", "-h", "--help"
        @stdout.puts(help)
        0
      else
        usage("unknown command: #{command}")
      end
    rescue Config::Error, RemoteRunner::Error, LocalRunner::Error => error
      @stderr.puts("error: #{error.message}")
      1
    end

    private

    def parse_global_options
      parsed = []
      index = 0
      while index < @argv.length
        arg = @argv[index]
        if arg == "--host"
          value = @argv[index + 1]
          raise Config::Error, "--host requires a value" unless value

          @host_id = value
          index += 2
        elsif arg.start_with?("--host=")
          @host_id = arg.split("=", 2).last
          index += 1
        else
          parsed << arg
          index += 1
        end
      end
      @argv = parsed
    end

    def host
      @config.host(@host_id)
    end

    def runner
      return @runner if defined?(@runner)

      @runner = if host.local?
        LocalRunner.new(stdout: @stdout, stderr: @stderr)
      else
        RemoteRunner.new(host, stdout: @stdout, stderr: @stderr)
      end
    end

    def service_runner
      return @service_runner if defined?(@service_runner)

      @service_runner = if host.local?
        LocalRunner.new(stdout: @stdout, stderr: @stderr)
      else
        RemoteRunner.new(host, stdout: @stdout, stderr: @stderr, ssh_target: host.service_ssh_target)
      end
    end

    def app_profile(id)
      @config.app(id)
    end

    def doctor
      script = <<~SH
        set -u
        echo "host=#{host.id}"
        echo "user=#{host.user}"
        echo "service_user=#{host.service_user}"
        echo "ssh_target=#{host.ssh_target}"
        echo "service_ssh_target=#{host.service_ssh_target}"
        echo "base_repo_path=#{host.base_repo_path}"
        echo "hostname=$(hostname)"
        printf "tailscale_ip="
        tailscale ip -4 2>/dev/null | head -n1 || true
        for cmd in git docker tmux mise op ruby; do
          if command -v "$cmd" >/dev/null 2>&1; then
            echo "$cmd=ok"
          else
            echo "$cmd=missing"
          fi
        done
        command -v docker >/dev/null 2>&1 && echo "runtime_docker_installed=yes" || echo "runtime_docker_installed=no"
        docker ps >/dev/null 2>&1 && echo "runtime_docker_access=yes" || echo "runtime_docker_access=no"
        if [ -d "#{host.base_repo_path}" ]; then
          echo "repos_dir=ok"
        else
          echo "repos_dir=missing"
        fi
      SH

      runner.run(script)
      service_runner.run(<<~SH)
        set -u
        echo "service_user=#{host.service_user}"
        echo "service_ssh_target=#{host.service_ssh_target}"
        command -v docker >/dev/null 2>&1 && echo "service_docker_installed=yes" || echo "service_docker_installed=no"
        docker ps >/dev/null 2>&1 && echo "service_docker_access=yes" || echo "service_docker_access=no"
      SH
    end

    def bootstrap
      compose = Shell.escape(host.services_compose_path)
      service_dir = Shell.escape(File.dirname(host.services_compose_path))
      repo_dir = Shell.escape(host.base_repo_path)
      registry_dir = Shell.escape(host.registry_dir)
      cert_dir = Shell.escape(host.cert_dir)
      content = Shell.single_quoted(host.services_compose)
      inspect_command = if host.local?
        "cat #{host.services_compose_path}"
      else
        "ssh #{host.service_ssh_target} 'cat #{host.services_compose_path}'"
      end

      runner.run(<<~SH)
        set -eu
        mkdir -p #{repo_dir} #{registry_dir} #{cert_dir}
        echo "host=#{host.id}"
        echo "runtime_user=#{host.user}"
        echo "runtime_dirs=#{host.base_repo_path},#{host.registry_dir},#{host.cert_dir}"
      SH

      service_runner.run(<<~SH)
        set -eu
        mkdir -p #{service_dir}
        printf %s #{content} > #{compose}
        echo "host=#{host.id}"
        echo "service_user=#{host.service_user}"
        echo "wrote=#{host.services_compose_path}"
        echo "inspect=#{inspect_command}"
      SH
    end

    def services
      action = @argv.shift
      return usage("missing services action") unless action

      compose = Shell.escape(host.services_compose_path)
      service_dir = Shell.escape(File.dirname(host.services_compose_path))

      case action
      when "up"
        service_runner.run("set -eu\n#{docker_access_guard}\ncd #{service_dir}\ndocker compose -f #{compose} up -d")
      when "down"
        service_runner.run("set -eu\n#{docker_access_guard}\ncd #{service_dir}\ndocker compose -f #{compose} down")
      when "logs"
        service_runner.run("set -eu\n#{docker_access_guard}\ncd #{service_dir}\ndocker compose -f #{compose} logs --tail=200")
      else
        usage("unknown services action: #{action}")
      end
    end

    def app
      action = @argv.shift
      return usage("missing app action") unless action

      case action
      when "list"
        @config.apps.each { |profile| @stdout.puts(profile.id) }
        0
      when "doctor"
        profile = app_profile(require_arg("app id"))
        app_doctor(profile)
      when "clone"
        profile = app_profile(require_arg("app id"))
        app_clone(profile)
      when "setup"
        profile = app_profile(require_arg("app id"))
        app_setup(profile)
      else
        usage("unknown app action: #{action}")
      end
    end

    def app_doctor(profile)
      runner.run(<<~SH)
        set -u
        echo "app=#{profile.id}"
        echo "repo=#{profile.repo}"
        echo "main_path=#{profile.main_path}"
        echo "worktree_root=#{profile.worktree_root}"
        echo "domain=#{profile.domain}"
        echo "base_port=#{profile.base_port}"
        [ -d #{Shell.escape(profile.main_path)} ] && echo "main_clone=ok" || echo "main_clone=missing"
        [ -d #{Shell.escape(profile.worktree_root)} ] && echo "worktree_root=ok" || echo "worktree_root=missing"
        [ -f #{Shell.escape(profile.env_shared_path)} ] && echo "shared_env=ok" || echo "shared_env=missing"
        for cmd in git tmux mise; do
          if command -v "$cmd" >/dev/null 2>&1; then
            echo "$cmd=ok"
          else
            echo "$cmd=missing"
          fi
        done
        if [ -d #{Shell.escape(profile.main_path)} ]; then
          cd #{Shell.escape(profile.main_path)}
          [ -f .ruby-version ] && echo "ruby_version_file=$(cat .ruby-version)" || echo "ruby_version_file=missing"
          [ -f .nvmrc ] && echo "node_version_file=$(cat .nvmrc)" || true
          if command -v mise >/dev/null 2>&1; then
            MISE_SPECS=""
            [ -f .ruby-version ] && MISE_SPECS="$MISE_SPECS ruby@$(cat .ruby-version)"
            [ -f .nvmrc ] && MISE_SPECS="$MISE_SPECS node@$(cat .nvmrc)"
            echo "mise_specs=${MISE_SPECS# }"
            ruby_output=$(mise exec $MISE_SPECS -- ruby -v 2>&1) && echo "ruby_runtime=$ruby_output" || echo "ruby_runtime_error=$ruby_output"
            bundle_output=$(mise exec $MISE_SPECS -- bundle -v 2>&1) && echo "bundle=ok $bundle_output" || echo "bundle=missing $bundle_output"
          else
            command -v ruby >/dev/null 2>&1 && echo "ruby_runtime=$(ruby -v)" || echo "ruby_runtime=missing"
            command -v bundle >/dev/null 2>&1 && echo "bundle=ok $(bundle -v)" || echo "bundle=missing"
          fi
        fi
      SH
    end

    def app_clone(profile)
      runner.run(<<~SH)
        set -eu
        mkdir -p #{Shell.escape(File.dirname(profile.main_path))}
        if [ -d #{Shell.escape(profile.main_path)}/.git ]; then
          echo "clone exists: #{profile.main_path}"
        else
          git clone #{Shell.escape(profile.repo)} #{Shell.escape(profile.main_path)}
        fi
        mkdir -p #{Shell.escape(profile.worktree_root)}
      SH
    end

    def app_setup(profile)
      runner.run(<<~SH)
        set -eu
        cd #{Shell.escape(profile.main_path)}
        if ! command -v mise >/dev/null 2>&1; then
          echo "mise is required for app setup because repo runtime files are the source of truth" >&2
          exit 1
        fi
        MISE_SPECS=""
        [ -f .ruby-version ] && MISE_SPECS="$MISE_SPECS ruby@$(cat .ruby-version)"
        [ -f .nvmrc ] && MISE_SPECS="$MISE_SPECS node@$(cat .nvmrc)"
        if [ -z "$MISE_SPECS" ]; then
          echo "no .ruby-version or .nvmrc found in #{profile.main_path}" >&2
          exit 1
        fi
        mise install --quiet $MISE_SPECS
        if ! mise exec $MISE_SPECS -- bundle -v >/dev/null 2>&1; then
          mise exec $MISE_SPECS -- gem install bundler
        fi
        echo "using repo runtime files via mise exec; no global activation is required"
        mise exec $MISE_SPECS -- ruby -v
        mise exec $MISE_SPECS -- bundle -v
      SH
    end

    def worktree
      action = @argv.shift
      return usage("missing worktree action") unless action

      profile = app_profile(require_arg("app id"))
      slug = require_arg("worktree slug")
      branch = @argv.shift

      case action
      when "create"
        worktree_create(profile, slug, branch)
      when "start"
        worktree_start(profile, slug)
      when "stop"
        worktree_stop(profile, slug)
      when "status"
        worktree_status(profile, slug)
      when "remove"
        worktree_remove(profile, slug)
      else
        usage("unknown worktree action: #{action}")
      end
    end

    def worktree_create(profile, slug, branch)
      profile_exports = shell_profile_exports(profile, slug)
      branch_name = branch || "feature/#{slug}"

      runner.run(<<~SH)
        set -eu
        #{profile_exports}
        export BRANCH=#{Shell.single_quoted(branch_name)}
        mkdir -p "$WORKTREE_ROOT" "$(dirname "$REGISTRY")"
        touch "$REGISTRY"
        if awk -F '\\t' -v slug="$SLUG" '$1 == slug { found=1 } END { exit found ? 0 : 1 }' "$REGISTRY"; then
          echo "worktree already registered: $SLUG"
          exit 0
        fi

        PORT=""
        i=1
        while [ "$i" -le "$PORT_COUNT" ]; do
          candidate=$((BASE_PORT + i))
          if ! awk -F '\\t' -v port="$candidate" '$2 == port { found=1 } END { exit found ? 0 : 1 }' "$REGISTRY" &&
             ! lsof -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then
            PORT="$candidate"
            break
          fi
          i=$((i + 1))
        done

        if [ -z "$PORT" ]; then
          echo "no available port in ${BASE_PORT}+1..$((BASE_PORT + PORT_COUNT))" >&2
          exit 1
        fi

        REDIS_DB=$((PORT - BASE_PORT))
        DB_NAME="${DB_PREFIX}_${SANITIZED}"
        WORKTREE_PATH="${WORKTREE_ROOT}/${SLUG}"
        SESSION="${APP_ID}_${SANITIZED}"

        cd "$MAIN_PATH"
        if [ -d "$WORKTREE_PATH" ]; then
          echo "worktree directory exists: $WORKTREE_PATH"
        elif git show-ref --verify --quiet "refs/heads/$BRANCH"; then
          git worktree add "$WORKTREE_PATH" "$BRANCH"
        else
          git worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD
        fi

        cd "$WORKTREE_PATH"
        if [ -f "$ENV_SHARED_PATH" ] && [ ! -e .env.local ]; then
          ln -s "$ENV_SHARED_PATH" .env.local
        fi
        if [ -f "$CERT_PATH" ] && [ ! -e app.crt ]; then
          ln -s "$CERT_PATH" app.crt
        fi
        if [ -f "$KEY_PATH" ] && [ ! -e app.key ]; then
          ln -s "$KEY_PATH" app.key
        fi

        cat > .env.development.local <<EOF
APP_DOMAIN=${DOMAIN}
DASHBOARD_DOMAIN=app.${DOMAIN}
APP_PORT=:${PORT}
PORT=${PORT}
DATABASE_NAME=${DB_NAME}
PGHOST=127.0.0.1
PGUSER=${PGUSER_VALUE}
PGPASSWORD=#{Shell.single_quoted(host.postgres_password)}
SPRUNG_DATABASE_PASSWORD=#{Shell.single_quoted(host.postgres_password)}
REDIS_URL=redis://127.0.0.1:6379/${REDIS_DB}
WEBSITE_URL=https://app.${DOMAIN}:${PORT}
API_URL=https://api.${DOMAIN}:${PORT}
EOF

        if command -v createdb >/dev/null 2>&1; then
          createdb "$DB_NAME" 2>/dev/null || true
        fi
        printf "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$SLUG" "$PORT" "$REDIS_DB" "$DB_NAME" "$WORKTREE_PATH" "$SESSION" >> "$REGISTRY"
        echo "created $APP_ID/$SLUG port=$PORT db=$DB_NAME redis_db=$REDIS_DB path=$WORKTREE_PATH"
      SH

      create_database(profile, slug)
    end

    def worktree_start(profile, slug)
      runner.run(<<~SH)
        set -eu
        #{shell_profile_exports(profile, slug)}
        row=$(awk -F '\\t' -v slug="$SLUG" '$1 == slug { print; exit }' "$REGISTRY")
        if [ -z "$row" ]; then
          echo "worktree is not registered: $SLUG" >&2
          exit 1
        fi
        IFS="$(printf '\\t')" read -r _ PORT REDIS_DB DB_NAME WORKTREE_PATH SESSION <<EOF
$row
EOF
        cd "$WORKTREE_PATH"
        AGENT_COMMAND=#{Shell.single_quoted(profile.agent_command)}
        WEB_COMMAND=#{Shell.single_quoted(profile.web_command)}
        WORKER_COMMAND=#{Shell.single_quoted(profile.worker_command)}
        ASSET_COMMAND_TEMPLATE=#{Shell.single_quoted(profile.asset_command)}
        WEB_COMMAND="${WEB_COMMAND//\\{port\\}/$PORT}"
        WEB_COMMAND="${WEB_COMMAND//\\{domain\\}/$DOMAIN}"
        WORKER_COMMAND="${WORKER_COMMAND//\\{port\\}/$PORT}"
        WORKER_COMMAND="${WORKER_COMMAND//\\{domain\\}/$DOMAIN}"
        ASSET_COMMAND_RENDERED="${ASSET_COMMAND_TEMPLATE//\\{port\\}/$PORT}"
        ASSET_COMMAND_RENDERED="${ASSET_COMMAND_RENDERED//\\{domain\\}/$DOMAIN}"
        if command -v mise >/dev/null 2>&1; then
          MISE_SPECS=""
          [ -f .ruby-version ] && MISE_SPECS="$MISE_SPECS ruby@$(cat .ruby-version)"
          [ -f .nvmrc ] && MISE_SPECS="$MISE_SPECS node@$(cat .nvmrc)"
          WEB_COMMAND="mise exec $MISE_SPECS -- $WEB_COMMAND"
          WORKER_COMMAND="mise exec $MISE_SPECS -- $WORKER_COMMAND"
          if [ -n "$ASSET_COMMAND_RENDERED" ]; then
            ASSET_COMMAND_RENDERED="mise exec $MISE_SPECS -- $ASSET_COMMAND_RENDERED"
          fi
        fi
        if tmux has-session -t "$SESSION" 2>/dev/null; then
          echo "session already running: $SESSION"
          exit 0
        fi
        tmux new-session -d -s "$SESSION" -n main
        tmux send-keys -t "$SESSION":main "pwd" C-m
        tmux split-window -h -t "$SESSION":main
        tmux send-keys -t "$SESSION":main.1 "$AGENT_COMMAND" C-m
        tmux new-window -t "$SESSION" -n services
        tmux send-keys -t "$SESSION":services "$WEB_COMMAND" C-m
        tmux split-window -v -t "$SESSION":services
        tmux send-keys -t "$SESSION":services.1 "$WORKER_COMMAND" C-m
        if [ -n "$ASSET_COMMAND_RENDERED" ]; then
          tmux split-window -v -t "$SESSION":services
          tmux send-keys -t "$SESSION":services.2 "$ASSET_COMMAND_RENDERED" C-m
        fi
        echo "started $SESSION"
        echo "url=https://app.${DOMAIN}:${PORT}"
      SH
    end

    def worktree_stop(profile, slug)
      runner.run(<<~SH)
        set -eu
        #{shell_profile_exports(profile, slug)}
        SESSION=$(awk -F '\\t' -v slug="$SLUG" '$1 == slug { print $6; exit }' "$REGISTRY")
        if [ -z "$SESSION" ]; then
          echo "worktree is not registered: $SLUG" >&2
          exit 1
        fi
        if tmux has-session -t "$SESSION" 2>/dev/null; then
          tmux kill-session -t "$SESSION"
          echo "stopped $SESSION"
        else
          echo "not running: $SESSION"
        fi
      SH
    end

    def worktree_status(profile, slug)
      runner.run(<<~SH)
        set -eu
        #{shell_profile_exports(profile, slug)}
        row=$(awk -F '\\t' -v slug="$SLUG" '$1 == slug { print; exit }' "$REGISTRY")
        if [ -z "$row" ]; then
          echo "registered=no"
          exit 0
        fi
        IFS="$(printf '\\t')" read -r SLUG_VALUE PORT REDIS_DB DB_NAME WORKTREE_PATH SESSION <<EOF
$row
EOF
        echo "registered=yes"
        echo "app=$APP_ID"
        echo "slug=$SLUG_VALUE"
        echo "port=$PORT"
        echo "redis_db=$REDIS_DB"
        echo "database=$DB_NAME"
        echo "path=$WORKTREE_PATH"
        echo "session=$SESSION"
        tmux has-session -t "$SESSION" 2>/dev/null && echo "running=yes" || echo "running=no"
        echo "url=https://app.${DOMAIN}:${PORT}"
      SH
    end

    def worktree_remove(profile, slug)
      runner.run(<<~SH)
        set -eu
        #{shell_profile_exports(profile, slug)}
        row=$(awk -F '\\t' -v slug="$SLUG" '$1 == slug { print; exit }' "$REGISTRY")
        if [ -z "$row" ]; then
          echo "worktree is not registered: $SLUG"
          exit 0
        fi
        IFS="$(printf '\\t')" read -r _ PORT REDIS_DB DB_NAME WORKTREE_PATH SESSION <<EOF
$row
EOF
        tmux has-session -t "$SESSION" 2>/dev/null && tmux kill-session -t "$SESSION" || true
        cd "$MAIN_PATH"
        git worktree remove "$WORKTREE_PATH" || rm -rf "$WORKTREE_PATH"
        if command -v dropdb >/dev/null 2>&1; then
          dropdb --if-exists "$DB_NAME" 2>/dev/null || true
        fi
        tmp="${REGISTRY}.tmp"
        awk -F '\\t' -v slug="$SLUG" '$1 != slug { print }' "$REGISTRY" > "$tmp"
        mv "$tmp" "$REGISTRY"
        echo "removed $APP_ID/$SLUG"
      SH

      drop_database(profile, slug)
    end

    def dns
      action = @argv.shift
      app_id = require_arg("app id")
      profile = app_profile(app_id)

      case action
      when "doctor"
        runner.run(<<~SH)
          set -u
          echo "domain=#{profile.domain}"
          echo "expected_host=#{host.id}"
          printf "host_tailscale_ip="
          tailscale ip -4 2>/dev/null | head -n1 || true
          echo "domain_a=$(dig +short #{Shell.escape(profile.domain)} A 2>/dev/null | tr '\\n' ' ')"
          echo "wildcard_a=$(dig +short app.#{Shell.escape(profile.domain)} A 2>/dev/null | tr '\\n' ' ')"
        SH
      when "sync"
        @stderr.puts("error: dns sync is not implemented yet; configure #{profile.domain} and *.#{profile.domain} to point at #{host.id}'s Tailscale IP")
        1
      else
        usage("unknown dns action: #{action}")
      end
    end

    def cert
      action = @argv.shift
      return usage("missing cert action") unless action

      profile = app_profile(require_arg("app id"))

      case action
      when "doctor"
        cert_doctor(profile)
      when "issue"
        cert_issue(profile)
      when "renew"
        cert_renew(profile)
      else
        usage("unknown cert action: #{action}")
      end
    end

    def cert_doctor(profile)
      cert_path = Shell.escape(profile.cert_path(host))
      key_path = Shell.escape(profile.key_path(host))

      runner.run(<<~SH)
        set -u
        echo "domain=#{profile.domain}"
        echo "wildcard=*.#{profile.domain}"
        echo "cert_path=#{profile.cert_path(host)}"
        echo "key_path=#{profile.key_path(host)}"
        [ -x "$HOME/.acme.sh/acme.sh" ] && echo "acme_sh=ok" || echo "acme_sh=missing"
        [ -f #{cert_path} ] && echo "cert=present" || echo "cert=missing"
        [ -f #{key_path} ] && echo "key=present" || echo "key=missing"
        if [ -f #{cert_path} ]; then
          openssl x509 -in #{cert_path} -noout -subject -issuer -dates 2>/dev/null || true
          openssl x509 -in #{cert_path} -noout -ext subjectAltName 2>/dev/null | sed 's/^/san_/' || true
        fi
      SH
    end

    def cert_issue(profile)
      run_acme_cert(profile, "issue")
    end

    def cert_renew(profile)
      run_acme_cert(profile, "renew")
    end

    def shell_profile_exports(profile, slug)
      sanitized = sanitize_slug(slug)
      registry = registry_path(profile)
      {
        "APP_ID" => profile.id,
        "SLUG" => slug,
        "SANITIZED" => sanitized,
        "MAIN_PATH" => profile.main_path,
        "WORKTREE_ROOT" => profile.worktree_root,
        "DOMAIN" => profile.domain,
        "BASE_PORT" => profile.base_port.to_s,
        "PORT_COUNT" => profile.port_count.to_s,
        "DB_PREFIX" => profile.database_prefix,
        "REGISTRY" => registry,
        "ENV_SHARED_PATH" => profile.env_shared_path,
        "CERT_PATH" => profile.cert_path(host),
        "KEY_PATH" => profile.key_path(host),
        "PGUSER_VALUE" => profile.pguser,
        "ASSET_COMMAND" => profile.asset_command.to_s
      }.map { |key, value| "export #{key}=#{Shell.single_quoted(value)}" }.join("\n")
    end

    def docker_access_guard
      <<~SH
        if ! command -v docker >/dev/null 2>&1; then
          echo "docker is not installed or not in PATH" >&2
          exit 1
        fi
        if ! docker ps >/dev/null 2>&1; then
          echo "docker is installed, but service_user #{host.service_user} cannot access the Docker daemon on #{host.id}" >&2
          echo "fix: ssh #{host.service_ssh_target} 'id && ls -l /var/run/docker.sock'" >&2
          echo "do not give Docker access to runtime user #{host.user}; change service_user instead" >&2
          exit 1
        fi
      SH
    end

    def create_database(profile, slug)
      db_name = "#{profile.database_prefix}_#{sanitize_slug(slug)}"
      service_runner.run(<<~SH)
        set -eu
        #{docker_access_guard}
        if docker ps --format '{{.Names}}' | grep -qx 'tesseract-postgres'; then
          docker exec tesseract-postgres createdb -U #{Shell.escape(profile.pguser)} #{Shell.escape(db_name)} 2>/dev/null || true
          echo "database_ready=#{db_name}"
        else
          echo "tesseract-postgres is not running; start services before creating databases" >&2
          exit 1
        fi
      SH
    end

    def drop_database(profile, slug)
      db_name = "#{profile.database_prefix}_#{sanitize_slug(slug)}"
      service_runner.run(<<~SH)
        set -eu
        #{docker_access_guard}
        if docker ps --format '{{.Names}}' | grep -qx 'tesseract-postgres'; then
          docker exec tesseract-postgres dropdb --if-exists -U #{Shell.escape(profile.pguser)} #{Shell.escape(db_name)} 2>/dev/null || true
          echo "database_removed=#{db_name}"
        fi
      SH
    end

    def run_acme_cert(profile, mode)
      token = ENV["CLOUDFLARE_API_TOKEN"]
      raise Config::Error, "CLOUDFLARE_API_TOKEN is required for cert #{mode}" if token.to_s.empty?

      domain = profile.domain
      cert_path = Shell.escape(profile.cert_path(host))
      key_path = Shell.escape(profile.key_path(host))
      cert_dir = Shell.escape(host.cert_dir)
      acme_action = if mode == "renew"
        "$ACME --renew --dns dns_cf --server letsencrypt -d #{Shell.escape(domain)} --ecc --force"
      else
        "$ACME --issue --dns dns_cf --server letsencrypt -d #{Shell.escape(domain)} -d #{Shell.escape("*.#{domain}")} --keylength ec-256 --force"
      end

      runner.run(<<~SH)
        set -eu
        export CF_Token=#{Shell.single_quoted(token)}
        ACME="$HOME/.acme.sh/acme.sh"
        if [ ! -x "$ACME" ]; then
          for cmd in curl tar mktemp; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
              echo "$cmd is required to install acme.sh" >&2
              exit 1
            fi
          done
          tmp_dir=$(mktemp -d)
          cleanup() {
            rm -rf "$tmp_dir"
          }
          trap cleanup EXIT
          curl -fsSL https://github.com/acmesh-official/acme.sh/archive/master.tar.gz -o "$tmp_dir/acme.sh.tar.gz"
          tar -xzf "$tmp_dir/acme.sh.tar.gz" -C "$tmp_dir"
          (cd "$tmp_dir/acme.sh-master" && ./acme.sh --install --force)
          if [ ! -x "$ACME" ]; then
            echo "acme.sh install did not create $ACME" >&2
            exit 1
          fi
        fi
        if [ ! -x "$ACME" ]; then
          echo "acme.sh install did not create $ACME" >&2
          exit 1
        fi

        mkdir -p #{cert_dir}
        #{acme_action}
        "$ACME" --install-cert -d #{Shell.escape(domain)} --ecc \\
          --fullchain-file #{cert_path} \\
          --key-file #{key_path}
        chmod 0644 #{cert_path}
        chmod 0600 #{key_path}
        unset CF_Token
        echo "cert_installed=#{profile.cert_path(host)}"
        echo "key_installed=#{profile.key_path(host)}"
        echo "restart_hint=tesseract worktree stop <app> <slug> --host #{host.id} && tesseract worktree start <app> <slug> --host #{host.id}"
      SH
    end

    def registry_path(profile)
      File.join(host.registry_dir, "#{profile.id}.tsv")
    end

    def sanitize_slug(slug)
      slug.tr("-", "_").gsub(/[^A-Za-z0-9_]/, "")
    end

    def require_arg(name)
      arg = @argv.shift
      raise Config::Error, "missing #{name}" unless arg

      arg
    end

    def usage(message)
      @stderr.puts("error: #{message}")
      @stderr.puts
      @stderr.puts(help)
      1
    end

    def help
      <<~HELP
        Usage:
          tesseract [--host HOST] doctor
          tesseract [--host HOST] bootstrap
          tesseract [--host HOST] services up|down|logs
          tesseract [--host HOST] app list
          tesseract [--host HOST] app doctor|clone|setup APP
          tesseract [--host HOST] worktree create|start|stop|status|remove APP SLUG [BRANCH]
          tesseract [--host HOST] dns doctor|sync APP
          tesseract [--host HOST] cert doctor|issue|renew APP

        HOST defaults to #{DEFAULT_HOST}.
      HELP
    end
  end
end
