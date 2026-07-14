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
      when "pages"
        pages
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
      changelog_registry = File.join(File.dirname(host.base_repo_path), ".codex", "state", "worktree-changelogs.json")
      changelog_base_url = host.pages_domain ? "https://#{host.pages_domain}" : ""

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

        changelog_for_path() {
          target="$1"
          base_url=#{Shell.single_quoted(changelog_base_url)}
          [ -n "$base_url" ] || { printf "-"; return; }
          token=$(ruby -rjson -rdigest -e '
            path = File.realpath(ARGV.fetch(1))
            token = Digest::SHA256.hexdigest("tesseract-worktree-changelog\\0\#{path}")[0, 40]
            if File.file?(ARGV.fetch(0))
              registry = JSON.parse(File.read(ARGV.fetch(0)))
              registered = registry[path]
              token = registered if registered.is_a?(String) && registered.match?(/\\A[0-9a-f]{40}\\z/)
            end
            print token
          ' #{Shell.escape(changelog_registry)} "$target" 2>/dev/null || true)
          if [ -n "$token" ]; then
            printf "%s/p/%s.html" "$base_url" "$token"
          else
            printf "-"
          fi
        }

        printf "%-32s %8s %-48s %s\\n" "TMUX" "RSS" "URL" "CHANGELOG"
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
                  changelog=$(changelog_for_path "$path")
                  printf "%-32s %8s %-48s %s\\n" "$tmux_session" "$rss" "$url" "$changelog"
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
      repo_tesseract_check = if profile.git_worktrees?
        'echo "repo_tesseract=not_required"'
      else
        "[ -x #{Shell.escape(File.join(profile.main_path, "bin", "tesseract"))} ] && echo \"repo_tesseract=ok\" || echo \"repo_tesseract=missing\""
      end
      shared_env_check = if profile.git_worktrees?
        'echo "shared_env=not_required"'
      else
        "[ -f #{Shell.escape(profile.env_shared_path)} ] && echo \"shared_env=ok\" || echo \"shared_env=missing\""
      end

      runner.run(<<~SH)
        set -u
        echo "app=#{profile.id}"
        echo "repo=#{profile.repo}"
        echo "main_path=#{profile.main_path}"
        echo "domain=#{profile.domain}"
        echo "worktree_driver=#{profile.worktree_driver}"
        [ -d #{Shell.escape(profile.main_path)} ] && echo "main_clone=ok" || echo "main_clone=missing"
        #{shared_env_check}
        #{repo_tesseract_check}
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
      apps = profiles.map { |profile| "#{profile.id}\t#{profile.main_path}\t#{profile.worktree_driver}" }

      runner.run(<<~SH)
        set -u
        found_file=$(mktemp)
        rm -f "$found_file"
        cleanup_worktree_list() {
          rm -f "$found_file"
        }
        trap cleanup_worktree_list EXIT
        printf "%-10s %-22s %-32s %s\\n" "APP" "WORKTREE" "TMUX" "URL"
        while IFS="$(printf '\\t')" read -r app main_path worktree_driver; do
          [ -n "$app" ] || continue
          [ -d "$main_path" ] || continue

          git -C "$main_path" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
            case "$line" in
              "worktree "*)
                path=${line#worktree }
                [ "$path" != "$main_path" ] || continue
                slug=$(basename "$path")
                if [ "$worktree_driver" = "git" ]; then
                  session="$(printf "%s_%s" "$app" "$(printf "%s" "$slug" | tr '-' '_' | tr -cd '[:alnum:]_')")"
                  if tmux has-session -t "=$session" 2>/dev/null; then
                    tmux_session="$session"
                  else
                    tmux_session="-"
                  fi
                  url="-"
                else
                  status=$("$main_path/bin/tesseract" worktree status "$slug" 2>/dev/null || true)
                  tmux_session=$(printf "%s\\n" "$status" | sed -n 's/^tmux_session=//p' | tail -n1)
                  [ -n "$tmux_session" ] || tmux_session=$(printf "%s\\n" "$status" | sed -n 's/^session=//p' | tail -n1)
                  url=$(printf "%s\\n" "$status" | sed -n 's/^url=//p' | tail -n1)
                fi
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
      return git_worktree_dispatch(profile, action, slug, extra_args) if profile.git_worktrees?

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

    def git_worktree_dispatch(profile, action, slug, extra_args)
      unless slug.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
        return usage("invalid worktree slug: #{slug}")
      end

      case action
      when "create"
        return usage("unexpected worktree create argument: #{extra_args[1]}") if extra_args.length > 1

        branch = extra_args.first || "feature/#{slug}"
        git_worktree_create(profile, slug, branch)
      when "status"
        return usage("unexpected worktree status argument: #{extra_args.first}") unless extra_args.empty?

        git_worktree_status(profile, slug)
      when "remove"
        force = extra_args == ["--force"]
        unless extra_args.empty? || force
          return usage("unexpected worktree remove argument: #{extra_args.first}")
        end

        git_worktree_remove(profile, slug, force: force)
      when "start"
        return usage("unexpected worktree start argument: #{extra_args.first}") unless extra_args.empty?

        git_worktree_start(profile, slug)
      when "stop"
        return usage("unexpected worktree stop argument: #{extra_args.first}") unless extra_args.empty?

        git_worktree_stop(profile, slug)
      else
        usage("unknown worktree action: #{action}")
      end
    end

    def git_worktree_create(profile, slug, branch)
      branch = branch.delete_prefix("origin/")

      runner.run(<<~SH)
        set -eu
        main_path=#{Shell.escape(profile.main_path)}
        worktree_root=#{Shell.escape(profile.worktree_root)}
        path="$worktree_root/#{slug}"
        branch=#{Shell.escape(branch)}
        default_branch=#{Shell.escape(profile.default_branch)}

        if [ ! -d "$main_path/.git" ]; then
          echo "main clone is missing at #{profile.main_path}; run: tesseract app clone #{profile.id} --host #{host.id}" >&2
          exit 1
        fi
        git check-ref-format --branch "$branch" >/dev/null
        mkdir -p "$worktree_root"
        if [ -e "$path" ]; then
          echo "worktree already exists: $path"
          exit 0
        fi

        git -C "$main_path" fetch --prune origin
        if git -C "$main_path" show-ref --verify --quiet "refs/heads/$branch"; then
          git -C "$main_path" worktree add "$path" "$branch"
        elif git -C "$main_path" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          git -C "$main_path" worktree add --track -b "$branch" "$path" "origin/$branch"
        else
          if git -C "$main_path" show-ref --verify --quiet "refs/remotes/origin/$default_branch"; then
            base_ref="origin/$default_branch"
          else
            base_ref="$default_branch"
          fi
          git -C "$main_path" worktree add --no-track -b "$branch" "$path" "$base_ref"
        fi

        echo "created #{profile.id}/#{slug} branch=$branch path=$path"
      SH
    end

    def git_worktree_status(profile, slug)
      runner.run(<<~SH)
        set -u
        path=#{Shell.escape(File.join(profile.worktree_root, slug))}
        session=#{Shell.escape(git_worktree_session(profile, slug))}
        echo "app=#{profile.id}"
        echo "slug=#{slug}"
        echo "path=$path"
        if [ -d "$path" ] && git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          echo "registered=yes"
          echo "branch=$(git -C "$path" branch --show-current)"
        else
          echo "registered=no"
        fi
        if tmux has-session -t "=$session" 2>/dev/null; then
          echo "running=yes"
        else
          echo "running=no"
        fi
        echo "tmux_session=$session"
        echo "url=-"
      SH
    end

    def git_worktree_start(profile, slug)
      runner.run(<<~SH)
        set -eu
        path=#{Shell.escape(File.join(profile.worktree_root, slug))}
        session=#{Shell.escape(git_worktree_session(profile, slug))}
        if [ ! -d "$path" ] || ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          echo "worktree is missing: $path" >&2
          exit 1
        fi
        if tmux has-session -t "=$session" 2>/dev/null; then
          echo "session already running: $session"
        else
          tmux new-session -d -s "$session" -n main -c "$path"
          echo "started $session"
        fi
        echo "path=$path"
        echo "tmux_session=$session"
        echo "url=-"
      SH
    end

    def git_worktree_stop(profile, slug)
      runner.run(<<~SH)
        set -u
        session=#{Shell.escape(git_worktree_session(profile, slug))}
        if tmux has-session -t "=$session" 2>/dev/null; then
          tmux kill-session -t "=$session"
          echo "stopped $session"
        else
          echo "not running: $session"
        fi
      SH
    end

    def git_worktree_remove(profile, slug, force:)
      force_arg = force ? "--force" : ""
      runner.run(<<~SH)
        set -eu
        main_path=#{Shell.escape(profile.main_path)}
        path=#{Shell.escape(File.join(profile.worktree_root, slug))}
        session=#{Shell.escape(git_worktree_session(profile, slug))}
        if [ ! -e "$path" ]; then
          echo "worktree is missing: $path" >&2
          exit 1
        fi
        if tmux has-session -t "=$session" 2>/dev/null; then
          tmux kill-session -t "=$session"
          echo "stopped $session"
        fi
        git -C "$main_path" worktree remove #{force_arg} "$path"
        git -C "$main_path" worktree prune
        echo "removed #{profile.id}/#{slug} path=$path"
      SH
    end

    def git_worktree_session(profile, slug)
      sanitized_slug = slug.tr("-", "_").gsub(/[^A-Za-z0-9_]/, "")
      "#{profile.id}_#{sanitized_slug}"
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

    def pages
      action = @argv.shift
      return usage("missing pages action") unless action

      pages_dir = Shell.escape(host.pages_dir)
      pages_port = 8080
      pages_session = "tesseract_pages"
      tunnel_session = "tesseract_pages_tunnel"
      pages_server_path = File.join(File.dirname(host.pages_dir), ".local", "share", "tesseract", "pages_server.py")
      custom_domain = host.pages_domain
      tunnel_token_path = host.pages_tunnel_token_path

      if custom_domain && tunnel_token_path.to_s.empty?
        raise Config::Error, "pages_tunnel_token_path is required when pages_domain is configured"
      end

      case action
      when "list"
        sort = "updated"
        until @argv.empty?
          argument = @argv.shift
          if argument == "--sort"
            sort = @argv.shift
            return usage("--sort requires a value") unless sort
          elsif argument.start_with?("--sort=")
            sort = argument.split("=", 2).last
          else
            return usage("unexpected pages list argument: #{argument}")
          end
        end
        return usage("invalid pages sort column: #{sort}") unless %w[updated title url].include?(sort)

        runner.run("set -- #{Shell.escape(sort)}\n" + <<~'SH')
          set -eu
          registry="$HOME/.obfuscated_pages.json"
          if [ ! -f "$registry" ]; then
            echo "none"
            exit 0
          fi
          ruby -EUTF-8:UTF-8 -rjson -rtime -e '
            data = JSON.parse(File.read(ARGV.fetch(0)))
            abort("invalid pages registry version") unless data["version"] == 1
            pages = data["pages"]
            abort("invalid pages registry: pages must be an array") unless pages.is_a?(Array)
            clean = ->(value) { value.to_s.gsub(/[\t\r\n]+/, " ").strip }
            truncate = lambda do |value, width|
              value.length > width ? "#{value[0, width - 3]}..." : value
            end
            rows = pages.map do |page|
              abort("invalid pages registry: page must be an object") unless page.is_a?(Hash)
              url = page["url"]
              title = page["title"]
              updated_at = page["updated_at"]
              unless [url, title, updated_at].all? { |value| value.is_a?(String) && !value.empty? }
                abort("invalid pages registry: url, title, and updated_at are required")
              end
              [clean.call(updated_at), clean.call(title), clean.call(url), clean.call(page["description"])]
            end
            format_row = lambda do |updated_at, title, url|
              format(
                "%-8s  %-56s  %-32s",
                updated_at,
                truncate.call(title, 56),
                url
              )
            end
            sort = ARGV.fetch(1)
            rows = case sort
                   when "updated" then rows.sort_by { |row| row[0] }.reverse
                   when "title" then rows.sort_by { |row| row[1].downcase }
                   when "url" then rows.sort_by { |row| row[2].downcase }
                   else abort("invalid pages sort column: #{sort}")
                   end
            puts format_row.call("UPDATED", "TITLE", "URL")
            rows.each do |updated_at, title, url, _description|
              date = Time.iso8601(updated_at).strftime("%y/%m/%d")
              puts format_row.call(date, title, url)
            end
          ' "$registry" "$1"
        SH
      when "start"
        return usage("unexpected pages argument: #{@argv.first}") unless @argv.empty?

        runner.run(<<~SH)
          set -eu
          for cmd in python3 tmux; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
              echo "$cmd is required for pages" >&2
              exit 1
            fi
          done
          mkdir -p #{pages_dir}
          mkdir -p #{Shell.escape(File.dirname(pages_server_path))}
          cat > #{Shell.escape(pages_server_path)} <<'PY'
          import argparse
          from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

          class NoIndexHandler(SimpleHTTPRequestHandler):
              crawler_tokens = (
                  "amazonbot", "applebot", "bingbot", "bytespider", "ccbot",
                  "claudebot", "duckduckbot", "facebookexternalhit", "googlebot",
                  "gptbot", "linkedinbot", "meta-externalagent", "perplexitybot",
                  "petalbot", "slurp", "yandexbot",
              )

              def is_crawler(self):
                  user_agent = self.headers.get("User-Agent", "").lower()
                  return any(token in user_agent for token in self.crawler_tokens)

              def reject_crawler(self):
                  self.send_response(403)
                  self.send_header("Content-Type", "text/plain; charset=utf-8")
                  self.end_headers()
                  if self.command != "HEAD":
                      self.wfile.write(b"Crawler access is disabled.\\n")

              def do_GET(self):
                  if self.path.split("?", 1)[0] != "/robots.txt" and self.is_crawler():
                      self.reject_crawler()
                      return
                  super().do_GET()

              def do_HEAD(self):
                  if self.path.split("?", 1)[0] != "/robots.txt" and self.is_crawler():
                      self.reject_crawler()
                      return
                  super().do_HEAD()

              def end_headers(self):
                  self.send_header(
                      "X-Robots-Tag",
                      "noindex, nofollow, noarchive, nosnippet, noimageindex",
                  )
                  super().end_headers()

          parser = argparse.ArgumentParser()
          parser.add_argument("--directory", required=True)
          parser.add_argument("--port", type=int, default=8080)
          args = parser.parse_args()
          handler = lambda *handler_args, **kwargs: NoIndexHandler(
              *handler_args, directory=args.directory, **kwargs
          )
          ThreadingHTTPServer(("127.0.0.1", args.port), handler).serve_forever()
          PY
          printf 'User-agent: *\nDisallow: /\n' > #{pages_dir}/robots.txt
          if ! tmux has-session -t #{Shell.escape("=#{pages_session}")} 2>/dev/null; then
            tmux new-session -d -s #{Shell.escape(pages_session)} \
              "python3 #{Shell.escape(pages_server_path)} --port #{pages_port} --directory #{pages_dir}"
          fi
          #{pages_start_proxy_script(custom_domain, tunnel_token_path, tunnel_session, pages_port)}
          echo "pages_dir=#{host.pages_dir}"
        SH
      when "status"
        return usage("unexpected pages argument: #{@argv.first}") unless @argv.empty?

        runner.run(<<~SH)
          set -eu
          echo "pages_dir=#{host.pages_dir}"
          if tmux has-session -t #{Shell.escape("=#{pages_session}")} 2>/dev/null; then
            echo "pages_server=running"
          else
            echo "pages_server=stopped"
          fi
          #{pages_status_proxy_script(custom_domain, tunnel_session)}
        SH
      when "stop"
        return usage("unexpected pages argument: #{@argv.first}") unless @argv.empty?

        runner.run(<<~SH)
          set -eu
          if command -v tailscale >/dev/null 2>&1; then
            tailscale funnel reset >/dev/null 2>&1 || true
          fi
          tmux kill-session -t #{Shell.escape("=#{tunnel_session}")} 2>/dev/null || true
          tmux kill-session -t #{Shell.escape("=#{pages_session}")} 2>/dev/null || true
          echo "pages_stopped=yes"
        SH
      else
        usage("unknown pages action: #{action}")
      end
    end

    def pages_start_proxy_script(custom_domain, tunnel_token_path, tunnel_session, pages_port)
      unless custom_domain
        return <<~SH.chomp
          if ! command -v tailscale >/dev/null 2>&1; then
            echo "tailscale is required for pages" >&2
            exit 1
          fi
          tailscale funnel --bg --yes #{pages_port}
          tailscale funnel status
        SH
      end

      cloudflared = "$HOME/.local/bin/cloudflared"
      <<~SH.chomp
        if [ ! -x "#{cloudflared}" ]; then
          echo "cloudflared is required at #{cloudflared}" >&2
          exit 1
        fi
        if [ ! -r #{Shell.escape(tunnel_token_path)} ]; then
          echo "missing Cloudflare tunnel token: #{tunnel_token_path}" >&2
          exit 1
        fi
        if command -v tailscale >/dev/null 2>&1; then
          tailscale funnel reset >/dev/null 2>&1 || true
        fi
        if ! tmux has-session -t #{Shell.escape("=#{tunnel_session}")} 2>/dev/null; then
          tmux new-session -d -s #{Shell.escape(tunnel_session)} \
            "#{cloudflared} tunnel --no-autoupdate run --token-file #{Shell.escape(tunnel_token_path)}"
        fi
        echo "pages_url=https://#{custom_domain}/"
      SH
    end

    def pages_status_proxy_script(custom_domain, tunnel_session)
      return "tailscale funnel status" unless custom_domain

      <<~SH.chomp
        if tmux has-session -t #{Shell.escape("=#{tunnel_session}")} 2>/dev/null; then
          echo "pages_tunnel=running"
        else
          echo "pages_tunnel=stopped"
        fi
        echo "pages_url=https://#{custom_domain}/"
      SH
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
          tesseract [--host HOST] pages list [--sort updated|title|url]
          tesseract [--host HOST] pages start|status|stop

        HOST defaults to #{DEFAULT_HOST}.
      HELP
    end
  end
end
