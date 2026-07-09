require "tesseract/config"
require "tesseract/interactive_runner"
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
      when "live"
        live
      when "bootstrap"
        bootstrap
      when "services"
        services
      when "app"
        app
      when "attach"
        attach
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

    def interactive_runner
      @interactive_runner ||= InteractiveRunner.new(host)
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

    def live
      apps = @config.apps.map { |profile| "#{profile.id}\t#{profile.main_path}" }

      runner.run(<<~SH)
        set -u
        found_file=$(mktemp)
        rm -f "$found_file"
        cleanup_live() {
          rm -f "$found_file"
        }
        trap cleanup_live EXIT

        rss_for_path() {
          target="$1"
          total_kb=0
          for cwd_link in /proc/[0-9]*/cwd; do
            [ -e "$cwd_link" ] || continue
            cwd=$(readlink -f "$cwd_link" 2>/dev/null || true)
            case "$cwd" in
              "$target"|"$target"/*)
                pid=${cwd_link#/proc/}
                pid=${pid%/cwd}
                rss_kb=$(awk '/^VmRSS:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || true)
                case "$rss_kb" in
                  ""|*[!0-9]*) rss_kb=0 ;;
                esac
                total_kb=$((total_kb + rss_kb))
                ;;
            esac
          done
          printf "%s" "$total_kb"
        }

        format_rss() {
          awk -v kb="$1" 'BEGIN {
            if (kb >= 1048576) {
              printf "%.1fGiB", kb / 1048576
            } else {
              printf "%dMiB", int((kb + 1023) / 1024)
            }
          }'
        }

        printf "%-32s %8s %s\\n" "TMUX" "RSS" "URL"
        while IFS="$(printf '\\t')" read -r app main_path; do
          [ -n "$app" ] || continue
          [ -d "$main_path" ] || continue
          [ -x "$main_path/bin/tesseract" ] || continue

          git -C "$main_path" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
            case "$line" in
              "worktree "*)
                path=${line#worktree }
                [ "$path" != "$main_path" ] || continue
                slug=$(basename "$path")
                status=$("$main_path/bin/tesseract" worktree status "$slug" 2>/dev/null || true)
                running=$(printf "%s\\n" "$status" | sed -n 's/^running=//p' | tail -n1)
                tmux_session=$(printf "%s\\n" "$status" | sed -n 's/^tmux_session=//p' | tail -n1)
                [ -n "$tmux_session" ] || tmux_session=$(printf "%s\\n" "$status" | sed -n 's/^session=//p' | tail -n1)
                url=$(printf "%s\\n" "$status" | sed -n 's/^url=//p' | tail -n1)
                if [ "$running" = "yes" ] && [ -n "$tmux_session" ] && [ -n "$url" ]; then
                  rss=$(format_rss "$(rss_for_path "$path")")
                  printf "%-32s %8s %s\\n" "$tmux_session" "$rss" "$url"
                  touch "$found_file"
                fi
                ;;
            esac
          done
        done <<'EOF'
#{apps.join("\n")}
EOF
        if [ ! -f "$found_file" ]; then
          echo "none"
        fi
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
      when "pull"
        profile = app_profile(require_arg("app id"))
        app_pull(profile)
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
        echo "domain=#{profile.domain}"
        [ -d #{Shell.escape(profile.main_path)} ] && echo "main_clone=ok" || echo "main_clone=missing"
        [ -f #{Shell.escape(profile.env_shared_path)} ] && echo "shared_env=ok" || echo "shared_env=missing"
        [ -x #{Shell.escape(File.join(profile.main_path, "bin", "tesseract"))} ] && echo "repo_tesseract=ok" || echo "repo_tesseract=missing"
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
            MISE_SPECS=#{Shell.single_quoted(profile.runtime_specs.join(" "))}
            if [ -z "$MISE_SPECS" ]; then
              [ -f .ruby-version ] && MISE_SPECS="$MISE_SPECS ruby@$(cat .ruby-version)"
              [ -f .nvmrc ] && MISE_SPECS="$MISE_SPECS node@$(cat .nvmrc)"
            fi
            echo "mise_specs=${MISE_SPECS# }"
            if [ -n "$MISE_SPECS" ]; then
              runtime_output=$(mise exec $MISE_SPECS -- sh -lc 'command -v ruby >/dev/null 2>&1 && ruby -v || node -v' 2>&1) && echo "runtime=$runtime_output" || echo "runtime_error=$runtime_output"
            fi
            bundle_output=$(mise exec $MISE_SPECS -- bundle -v 2>&1) && echo "bundle=ok $bundle_output" || true
            pnpm_output=$(mise exec $MISE_SPECS -- pnpm -v 2>&1) && echo "pnpm=ok $pnpm_output" || true
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
          env_backup=""
          if [ -d #{Shell.escape(profile.main_path)} ] && [ ! -d #{Shell.escape(profile.main_path)}/.git ]; then
            if [ -f #{Shell.escape(profile.env_shared_path)} ]; then
              env_backup=$(mktemp)
              cp #{Shell.escape(profile.env_shared_path)} "$env_backup"
            fi
            if find #{Shell.escape(profile.main_path)} -mindepth 1 ! -name .env.local | grep -q .; then
              echo "refusing to clone into non-empty non-git directory: #{profile.main_path}" >&2
              exit 1
            fi
            rm -rf #{Shell.escape(profile.main_path)}
          fi
          git clone #{Shell.escape(profile.repo)} #{Shell.escape(profile.main_path)}
          if [ -n "$env_backup" ]; then
            cp "$env_backup" #{Shell.escape(profile.env_shared_path)}
            chmod 0600 #{Shell.escape(profile.env_shared_path)}
            rm -f "$env_backup"
          fi
        fi
        #{profile.worktree_root ? "mkdir -p #{Shell.escape(profile.worktree_root)}" : ":"}
      SH
    end

    def app_pull(profile)
      runner.run(<<~SH)
        set -eu
        cd #{Shell.escape(profile.main_path)}
        if [ ! -d .git ]; then
          echo "main clone is missing at #{profile.main_path}; run: tesseract app clone #{profile.id} --host #{host.id}" >&2
          exit 1
        fi
        if [ -n "$(git status --porcelain)" ]; then
          echo "refusing to pull origin main because #{profile.main_path} has local changes" >&2
          git status --short >&2
          exit 1
        fi
        git pull --ff-only origin main
        echo "pulled_origin_main=#{profile.main_path}"
      SH
    end

    def app_setup(profile)
      runner.run(<<~SH)
        set -eu
        cd #{Shell.escape(profile.main_path)}
        if [ ! -d .git ]; then
          echo "main clone is missing at #{profile.main_path}; run: tesseract app clone #{profile.id} --host #{host.id}" >&2
          exit 1
        fi
        if ! command -v mise >/dev/null 2>&1; then
          echo "mise is required for app setup because repo runtime files are the source of truth" >&2
          exit 1
        fi
        MISE_SPECS=""
        CONFIGURED_SPECS=#{Shell.single_quoted(profile.runtime_specs.join(" "))}
        if [ -n "$CONFIGURED_SPECS" ]; then
          MISE_SPECS="$CONFIGURED_SPECS"
        else
          [ -f .ruby-version ] && MISE_SPECS="$MISE_SPECS ruby@$(cat .ruby-version)"
          [ -f .nvmrc ] && MISE_SPECS="$MISE_SPECS node@$(cat .nvmrc)"
        fi
        if [ -z "$MISE_SPECS" ]; then
          echo "no runtime specs configured and no .ruby-version or .nvmrc found in #{profile.main_path}" >&2
          exit 1
        fi
        mise install --quiet $MISE_SPECS
        if #{profile.setup_commands.empty? ? "true" : "false"} && ! mise exec $MISE_SPECS -- bundle -v >/dev/null 2>&1; then
          mise exec $MISE_SPECS -- gem install bundler
        fi
        echo "using repo runtime files via mise exec; no global activation is required"
        #{runtime_probe_commands(profile)}
        #{setup_commands_script(profile)}
      SH
    end

    def attach
      session = require_arg("tmux session")
      return usage("unexpected attach argument: #{@argv.first}") unless @argv.empty?

      interactive_runner.attach(session)
    end

    def worktree
      action = @argv.shift
      return usage("missing worktree action") unless action

      if action == "list"
        app_id = @argv.shift
        profiles = app_id ? [app_profile(app_id)] : @config.apps
        return usage("unexpected worktree list argument: #{@argv.first}") unless @argv.empty?

        return worktree_list(profiles)
      end

      profile = app_profile(require_arg("app id"))
      slug = require_arg("worktree slug")
      extra_args = @argv

      case action
      when "create", "start", "stop", "status", "remove"
        worktree_dispatch(profile, action, slug, extra_args)
      else
        usage("unknown worktree action: #{action}")
      end
    end

    def worktree_list(profiles)
      apps = profiles.map { |profile| "#{profile.id}\t#{profile.main_path}" }

      runner.run(<<~SH)
        set -u
        found_file=$(mktemp)
        rm -f "$found_file"
        cleanup_worktree_list() {
          rm -f "$found_file"
        }
        trap cleanup_worktree_list EXIT
        printf "%-10s %-22s %-32s %s\\n" "APP" "WORKTREE" "TMUX" "URL"
        while IFS="$(printf '\\t')" read -r app main_path; do
          [ -n "$app" ] || continue
          [ -d "$main_path" ] || continue
          [ -x "$main_path/bin/tesseract" ] || continue

          git -C "$main_path" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
            case "$line" in
              "worktree "*)
                path=${line#worktree }
                [ "$path" != "$main_path" ] || continue
                slug=$(basename "$path")
                status=$("$main_path/bin/tesseract" worktree status "$slug" 2>/dev/null || true)
                tmux_session=$(printf "%s\\n" "$status" | sed -n 's/^tmux_session=//p' | tail -n1)
                [ -n "$tmux_session" ] || tmux_session=$(printf "%s\\n" "$status" | sed -n 's/^session=//p' | tail -n1)
                url=$(printf "%s\\n" "$status" | sed -n 's/^url=//p' | tail -n1)
                [ -n "$tmux_session" ] || tmux_session="-"
                [ -n "$url" ] || url="-"
                printf "%-10s %-22s %-32s %s\\n" "$app" "$slug" "$tmux_session" "$url"
                touch "$found_file"
                ;;
            esac
          done
        done <<'EOF'
#{apps.join("\n")}
EOF
        if [ ! -f "$found_file" ]; then
          echo "none"
        fi
      SH
    end

    def worktree_dispatch(profile, action, slug, extra_args)
      args = ["worktree", action, slug, *extra_args].map { |arg| Shell.escape(arg) }.join(" ")
      runner.run(<<~SH)
        set -eu
        cd #{Shell.escape(profile.main_path)}
        if [ ! -x ./bin/tesseract ]; then
          echo "missing repo-local ./bin/tesseract in #{profile.main_path}" >&2
          exit 1
        fi
        exec ./bin/tesseract #{args}
      SH
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
          while IFS= read -r record; do
            [ -n "$record" ] || continue
            value=$(dig +short "$record" A 2>/dev/null | tr '\\n' ' ')
            echo "record_a[$record]=$value"
          done <<'EOF'
#{profile.dns_records.join("\n")}
EOF
        SH
      when "sync"
        dns_sync(profile)
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
        "DATABASE_ENABLED" => profile.database_enabled?.to_s,
        "MISE_SPECS" => profile.runtime_specs.join(" "),
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

    def runtime_probe_commands(profile)
      if profile.setup_commands.empty?
        <<~SH.chomp
          mise exec $MISE_SPECS -- ruby -v
          mise exec $MISE_SPECS -- bundle -v
        SH
      else
        <<~SH.chomp
          mise exec $MISE_SPECS -- node -v
          mise exec $MISE_SPECS -- corepack --version
        SH
      end
    end

    def setup_commands_script(profile)
      profile.setup_commands.map do |command|
        "mise exec $MISE_SPECS -- #{command}"
      end.join("\n")
    end

    def worktree_setup_commands_script(profile)
      setup_commands_script(profile)
    end

    def env_overrides_content(profile)
      profile.env_overrides.map do |key, value|
        rendered = value.to_s.gsub("{port}", "${PORT}").gsub("{domain}", "${DOMAIN}")
        "#{key}=#{rendered}"
      end.join("\n")
    end

    def dns_sync(profile)
      token = ENV["CLOUDFLARE_API_TOKEN"]
      raise Config::Error, "CLOUDFLARE_API_TOKEN is required for dns sync" if token.to_s.empty?

      records = profile.dns_records.join("\n")

      runner.run(<<~SH)
        set -eu
        for cmd in curl ruby tailscale; do
          if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "$cmd is required for dns sync" >&2
            exit 1
          fi
        done

        CF_TOKEN=#{Shell.single_quoted(token)}
        ZONE_NAME=#{Shell.single_quoted(profile.dns_zone)}
        HOST_IP=$(tailscale ip -4 2>/dev/null | head -n1)
        if [ -z "$HOST_IP" ]; then
          echo "could not determine #{host.id} Tailscale IPv4 address" >&2
          exit 1
        fi

        api_get() {
          curl -fsS \\
            -H "Authorization: Bearer $CF_TOKEN" \\
            -H "Content-Type: application/json" \\
            "$1"
        }

        api_write() {
          method="$1"
          url="$2"
          data="$3"
          curl -fsS \\
            -X "$method" \\
            -H "Authorization: Bearer $CF_TOKEN" \\
            -H "Content-Type: application/json" \\
            --data "$data" \\
            "$url" >/dev/null
        }

        zone_response=$(api_get "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME")
        ZONE_ID=$(printf "%s" "$zone_response" | ruby -rjson -e 'data = JSON.parse(STDIN.read); zone = data.fetch("result").first; abort("zone not found") unless zone; print zone.fetch("id")')

        while IFS= read -r record_name; do
          [ -n "$record_name" ] || continue
          escaped_record=$(ruby -rjson -e 'print JSON.generate(ARGV.fetch(0))' "$record_name")
          escaped_ip=$(ruby -rjson -e 'print JSON.generate(ARGV.fetch(0))' "$HOST_IP")
          payload=$(printf '{"type":"A","name":%s,"content":%s,"ttl":1,"proxied":false}' "$escaped_record" "$escaped_ip")
          query_name=$(ruby -ruri -e 'print URI.encode_www_form_component(ARGV.fetch(0))' "$record_name")
          record_response=$(api_get "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$query_name")
          RECORD_ID=$(printf "%s" "$record_response" | ruby -rjson -e 'data = JSON.parse(STDIN.read); record = data.fetch("result").first; print(record ? record.fetch("id") : "")')

          if [ -n "$RECORD_ID" ]; then
            api_write PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" "$payload"
            echo "updated_dns=$record_name A $HOST_IP"
          else
            api_write POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" "$payload"
            echo "created_dns=$record_name A $HOST_IP"
          fi
        done <<'EOF'
#{records}
EOF

        unset CF_TOKEN
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
          tesseract [--host HOST] live
          tesseract [--host HOST] bootstrap
          tesseract [--host HOST] services up|down|logs
          tesseract [--host HOST] app list
          tesseract [--host HOST] app doctor|clone|pull|setup APP
          tesseract [--host HOST] attach SESSION
          tesseract [--host HOST] worktree list [APP]
          tesseract [--host HOST] worktree create|start|stop|status|remove APP SLUG [BRANCH]
          tesseract [--host HOST] dns doctor|sync APP
          tesseract [--host HOST] cert doctor|issue|renew APP

        HOST defaults to #{DEFAULT_HOST}.
      HELP
    end
  end
end
