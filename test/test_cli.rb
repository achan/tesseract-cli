require "minitest/autorun"
require "json"
require "open3"
require "stringio"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "tesseract/cli"

class CLITest < Minitest::Test
  class ScriptCaptureRunner
    attr_reader :scripts

    def initialize
      @scripts = []
    end

    def run(script)
      @scripts << script
      0
    end
  end

  class AttachCaptureRunner
    attr_reader :session

    def attach(session)
      @session = session
      0
    end
  end

  def run_cli(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = Tesseract::CLI.new(
      argv,
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    ).run
    [status, stdout.string, stderr.string]
  end

  def test_help
    status, stdout, stderr = run_cli("help")

    assert_equal 0, status
    assert_includes stdout, "HOST defaults to tars"
    assert_includes stdout, "cert doctor|issue|renew APP"
    assert_includes stdout, "pages list [--sort updated|title|url] [--page N] [--per-page N]"
    assert_empty stderr
  end

  def test_pages_list_reads_conventional_host_registry
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "pages", "list"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_equal "set -- 'updated' '1' '10'", script.lines.first.strip
    assert_includes script, '$HOME/.obfuscated_pages.json'
    assert_includes script, "ruby -EUTF-8:UTF-8 -rjson -rtime"
    assert_includes script, "invalid pages registry version"
    assert_includes script, '"%-8s  %-56s  %-32s"'
    assert_includes script, 'Time.iso8601(updated_at).strftime("%y/%m/%d")'
    assert_includes script, 'truncate.call(title, 56)'
    refute_includes script, 'truncate.call(description'
    assert_includes script, 'url'
    assert_includes script, 'when "updated" then rows.sort_by { |row| row[0] }.reverse'
    assert_includes script, 'rows.slice((page - 1) * per_page, per_page)'
    assert_includes script, 'puts "Page #{page}/#{page_count} (#{pages.length} total)"'
    assert_empty stderr.string
  end

  def test_pages_list_sorts_by_title
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["pages", "list", "--sort", "title"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_equal "set -- 'title' '1' '10'", script.lines.first.strip
    assert_includes script, 'when "title" then rows.sort_by { |row| row[1].downcase }'
    assert_empty stderr.string
  end

  def test_pages_list_accepts_page_and_per_page
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["pages", "list", "--page", "2", "--per-page=5"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_equal "set -- 'updated' '2' '5'", script.lines.first.strip
    assert_empty stderr.string
  end

  def test_pages_list_paginates_registry_output
    Dir.mktmpdir do |home|
      pages = 12.times.map do |index|
        number = index + 1
        {
          "url" => "https://example.com/page-#{number}",
          "title" => "Page #{number}",
          "updated_at" => format("2026-07-%02dT12:00:00Z", number)
        }
      end
      File.write(
        File.join(home, ".obfuscated_pages.json"),
        JSON.generate("version" => 1, "pages" => pages)
      )

      first_page = pages_list_script
      stdout, stderr, status = Open3.capture3({"HOME" => home}, "sh", stdin_data: first_page)

      assert status.success?, stderr
      assert_equal 10, stdout.lines.grep(/^26\/07\//).length
      assert_includes stdout, "Page 12"
      assert_includes stdout, "Page 1/2 (12 total)"

      second_page = pages_list_script("--page", "2")
      stdout, stderr, status = Open3.capture3({"HOME" => home}, "sh", stdin_data: second_page)

      assert status.success?, stderr
      assert_equal 2, stdout.lines.grep(/^26\/07\//).length
      assert_includes stdout, "Page 2/2 (12 total)"
    end
  end

  def test_pages_list_rejects_invalid_page
    status, _stdout, stderr = run_cli("pages", "list", "--page", "0")

    assert_equal 1, status
    assert_includes stderr, "invalid pages page: 0"
  end

  def test_pages_list_rejects_invalid_per_page
    status, _stdout, stderr = run_cli("pages", "list", "--per-page", "many")

    assert_equal 1, status
    assert_includes stderr, "invalid pages per-page: many"
  end

  def test_pages_list_rejects_invalid_sort_column
    status, _stdout, stderr = run_cli("pages", "list", "--sort", "description")

    assert_equal 1, status
    assert_includes stderr, "invalid pages sort column: description"
  end

  def test_pages_start_serves_configured_directory_with_cloudflare_tunnel
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "pages", "start"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "mkdir -p '/home/bot/pages'"
    assert_includes script, "class NoIndexHandler(SimpleHTTPRequestHandler):"
    assert_includes script, '"X-Robots-Tag"'
    assert_includes script, '"noindex, nofollow, noarchive, nosnippet, noimageindex"'
    assert_includes script, '"googlebot"'
    assert_includes script, "self.reject_crawler()"
    assert_includes script, "printf 'User-agent: *\nDisallow: /\n' > '/home/bot/pages'/robots.txt"
    assert_includes script, "python3 '/home/bot/.local/share/tesseract/pages_server.py' --port 8080 --directory '/home/bot/pages'"
    assert_includes script, "$HOME/.local/bin/cloudflared tunnel --no-autoupdate run --token-file '/home/bot/.config/tesseract/pages-tunnel.token'"
    assert_includes script, "pages_url=https://pages-tars.achan.bot/"
    assert_empty stderr.string
  end

  def test_pages_stop_resets_tailscale_funnel
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "pages", "stop"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run

    assert_equal 0, status
    assert_includes runner.scripts.fetch(0), "tailscale funnel reset"
    assert_includes runner.scripts.fetch(0), "tmux kill-session -t '=tesseract_pages_tunnel'"
    assert_includes runner.scripts.fetch(0), "tmux kill-session -t '=tesseract_pages'"
    assert_empty stderr.string
  end

  def test_app_list
    status, stdout, stderr = run_cli("--host", "local", "app", "list")

    assert_equal 0, status
    assert_includes stdout, "docovia"
    assert_includes stdout, "flexday"
    assert_includes stdout, "tesseract-web"
    assert_empty stderr
  end

  def test_live_prints_running_worktree_urls
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "live"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "TMUX"
    assert_includes script, "RSS"
    assert_includes script, "URL"
    assert_includes script, "CHANGELOG"
    assert_includes script, "/home/bot/repos/sprung-app"
    assert_includes script, "/home/bot/repos/flexday"
    assert_includes script, "/home/bot/repos/tesseract-web"
    assert_includes script, "rss_for_path()"
    assert_includes script, "/proc/[0-9]*/cwd"
    assert_includes script, "VmRSS:"
    assert_includes script, "format_rss()"
    assert_includes script, "changelog_for_path()"
    assert_includes script, "/home/bot/.codex/state/worktree-changelogs.json"
    assert_includes script, "Digest::SHA256.hexdigest"
    assert_includes script, "https://pages-tars.achan.bot"
    assert_includes script, "git -C \"$main_path\" worktree list --porcelain"
    assert_includes script, "\"$main_path/bin/tesseract\" worktree status \"$slug\""
    assert_includes script, "running="
    assert_includes script, "tmux_session="
    assert_includes script, "session="
    assert_includes script, "url="
    assert_empty stderr.string
  end

  def test_global_host_can_follow_command
    status, stdout, stderr = run_cli("app", "list", "--host", "local")

    assert_equal 0, status
    assert_includes stdout, "docovia"
    assert_empty stderr
  end

  def test_global_host_can_use_equals_syntax
    status, stdout, stderr = run_cli("--host=local", "app", "list")

    assert_equal 0, status
    assert_includes stdout, "docovia"
    assert_empty stderr
  end

  def test_worktree_create_dispatches_to_repo_tesseract
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    service_runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "create", "docovia", "demo", "existing-branch"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)
    cli.instance_variable_set(:@service_runner, service_runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_empty service_runner.scripts
    assert_includes script, "cd '/home/bot/repos/sprung-app'"
    assert_includes script, "missing repo-local ./bin/tesseract in /home/bot/repos/sprung-app"
    assert_includes script, "exec ./bin/tesseract 'worktree' 'create' 'demo' 'existing-branch'"
    refute_includes script, "docker exec tesseract-postgres"
    assert_empty stderr.string
  end

  def test_worktree_list_prints_worktree_tmux_session_and_url
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "list"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "APP"
    assert_includes script, "WORKTREE"
    assert_includes script, "TMUX"
    assert_includes script, "URL"
    assert_includes script, "/home/bot/repos/sprung-app"
    assert_includes script, "/home/bot/repos/flexday"
    assert_includes script, "/home/bot/repos/tesseract-web"
    assert_includes script, "git -C \"$main_path\" worktree list --porcelain"
    assert_includes script, "\"$main_path/bin/tesseract\" worktree status \"$slug\""
    assert_includes script, "tmux_session="
    assert_includes script, "session="
    assert_includes script, "url="
    assert_empty stderr.string
  end

  def test_worktree_list_can_filter_to_one_app
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "list", "flexday"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "/home/bot/repos/flexday"
    refute_includes script, "/home/bot/repos/sprung-app"
    assert_empty stderr.string
  end

  def test_worktree_start_dispatches_to_repo_tesseract
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "start", "flexday", "demo"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "cd '/home/bot/repos/flexday'"
    assert_includes script, "exec ./bin/tesseract 'worktree' 'start' 'demo'"
    assert_empty stderr.string
  end

  def test_tesseract_web_worktree_start_dispatches_to_repo_adapter
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "start", "tesseract-web", "demo"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "cd '/home/bot/repos/tesseract-web'"
    assert_includes script, "exec ./bin/tesseract 'worktree' 'start' 'demo'"
    assert_empty stderr.string
  end

  def test_signatures_worktree_create_uses_git_only_driver
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "create", "signatures", "portal", "feature/portal"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "main_path='/home/bot/repos/signatures'"
    assert_includes script, "worktree_root='/home/bot/repos/signatures-worktrees'"
    assert_includes script, "branch='feature/portal'"
    assert_includes script, 'git -C "$main_path" worktree add'
    assert_includes script, 'worktree add --no-track -b "$branch"'
    refute_includes script, "./bin/tesseract"
    assert_empty stderr.string
  end

  def test_chrome_extensions_worktree_create_uses_git_only_driver
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["worktree", "create", "chrome-extensions", "manifest-v3"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "main_path='/home/bot/repos/chrome-extensions'"
    assert_includes script, "worktree_root='/home/bot/repos/chrome-extensions-worktrees'"
    assert_includes script, "branch='feature/manifest-v3'"
    assert_includes script, 'git -C "$main_path" worktree add'
    refute_includes script, "./bin/tesseract"
    assert_empty stderr.string
  end

  def test_chrome_extensions_worktree_start_creates_normalized_tmux_session
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["worktree", "start", "chrome-extensions", "manifest-v3"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "path='/home/bot/repos/chrome-extensions-worktrees/manifest-v3'"
    assert_includes script, "session='chrome_extensions_manifest_v3'"
    assert_includes script, 'tmux new-session -d -s "$session" -n main -c "$path"'
    assert_includes script, 'echo "url=-"'
    refute_includes script, "url=https://"
    assert_empty stderr.string
  end

  def test_signatures_worktree_create_defaults_to_feature_branch
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["worktree", "create", "signatures", "portal"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run

    assert_equal 0, status
    assert_includes runner.scripts.fetch(0), "branch='feature/portal'"
    assert_empty stderr.string
  end

  def test_signatures_worktree_create_accepts_origin_prefixed_branch
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["worktree", "create", "signatures", "portal", "origin/feature/portal"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run

    assert_equal 0, status
    assert_includes runner.scripts.fetch(0), "branch='feature/portal'"
    assert_empty stderr.string
  end

  def test_signatures_worktree_start_creates_conventional_tmux_session
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["worktree", "start", "signatures", "portal"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "path='/home/bot/repos/signatures-worktrees/portal'"
    assert_includes script, "session='signatures_portal'"
    assert_includes script, 'tmux new-session -d -s "$session" -n main -c "$path"'
    assert_includes script, 'tmux has-session -t "=$session"'
    assert_empty stderr.string
  end

  def test_signatures_worktree_stop_kills_conventional_tmux_session
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["worktree", "stop", "signatures", "portal-refresh"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "session='signatures_portal_refresh'"
    assert_includes script, 'tmux kill-session -t "=$session"'
    assert_empty stderr.string
  end

  def test_signatures_worktree_remove_preserves_git_safety_by_default
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["worktree", "remove", "signatures", "portal"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, 'git -C "$main_path" worktree remove  "$path"'
    assert_includes script, "session='signatures_portal'"
    assert_includes script, 'tmux kill-session -t "=$session"'
    refute_includes script, "worktree remove --force"
    assert_empty stderr.string
  end

  def test_worktree_remove_passes_force_to_repo_tesseract
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "remove", "docovia", "demo", "--force"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "exec ./bin/tesseract 'worktree' 'remove' 'demo' '--force'"
    assert_empty stderr.string
  end

  def test_attach_uses_interactive_runner_for_tmux_session
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    attach_runner = AttachCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["attach", "docovia_exam_viewer_optimization", "--host", "tars"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)
    cli.instance_variable_set(:@interactive_runner, attach_runner)

    status = cli.run

    assert_equal 0, status
    assert_equal "docovia_exam_viewer_optimization", attach_runner.session
    assert_empty runner.scripts
    assert_empty stdout.string
    assert_empty stderr.string
  end

  def test_attach_rejects_extra_arguments
    status, _stdout, stderr = run_cli("attach", "docovia_exam_viewer_optimization", "extra", "--host", "local")

    assert_equal 1, status
    assert_includes stderr, "unexpected attach argument: extra"
  end

  def test_interactive_runner_builds_remote_tmux_attach_command
    config = Tesseract::Config.new(File.expand_path("..", __dir__))
    host = config.host("tars")
    runner = Tesseract::InteractiveRunner.new(host)

    command = runner.attach_command("docovia_exam_viewer_optimization")
    script = command.last

    assert_equal ["ssh", "-t", "-o", "SendEnv=none", "bot@tars"], command.first(5)
    assert_includes script, "export PATH="
    assert_includes script, "exec tmux attach -t '\\''docovia_exam_viewer_optimization'\\''"
    refute_includes script, "worktree status"
  end

  def test_interactive_runner_includes_case_extra_path
    config = Tesseract::Config.new(File.expand_path("..", __dir__))
    host = config.host("case")
    runner = Tesseract::InteractiveRunner.new(host)

    script = runner.attach_command("eso_pr_2").last

    assert_includes script, "/Users/bot/.homebrew/bin"
    assert_includes script, "exec tmux attach -t '\\''eso_pr_2'\\''"
  end

  def test_app_clone_preserves_seeded_env_only_directory
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "app", "clone", "flexday"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "env_backup=$(mktemp)"
    assert_includes script, "cp '/home/bot/repos/flexday/.env.local' \"$env_backup\""
    assert_includes script, "rm -rf '/home/bot/repos/flexday'"
    assert_includes script, "git clone 'git@github.com:FlexdayInc/flexday' '/home/bot/repos/flexday'"
    assert_includes script, "chmod 0600 '/home/bot/repos/flexday/.env.local'"
    assert_empty stderr.string
  end

  def test_app_pull_refuses_dirty_repo_before_pull
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "app", "pull", "docovia"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "cd '/home/bot/repos/sprung-app'"
    assert_includes script, "main clone is missing at /home/bot/repos/sprung-app"
    assert_includes script, "git status --porcelain"
    assert_includes script, "refusing to pull origin main because /home/bot/repos/sprung-app has local changes"
    assert_includes script, "git status --short >&2"
    assert_includes script, "git pull --ff-only origin main"
    assert_includes script, "pulled_origin_main=/home/bot/repos/sprung-app"
    assert_empty stderr.string
  end

  def test_cert_issue_requires_cloudflare_token
    old_token = ENV.delete("CLOUDFLARE_API_TOKEN")

    status, _stdout, stderr = run_cli("--host", "tars", "cert", "issue", "docovia")

    assert_equal 1, status
    assert_includes stderr, "CLOUDFLARE_API_TOKEN is required"
  ensure
    ENV["CLOUDFLARE_API_TOKEN"] = old_token if old_token
  end

  def test_dns_sync_requires_cloudflare_token
    old_token = ENV.delete("CLOUDFLARE_API_TOKEN")

    status, _stdout, stderr = run_cli("--host", "tars", "dns", "sync", "flexday")

    assert_equal 1, status
    assert_includes stderr, "CLOUDFLARE_API_TOKEN is required for dns sync"
  ensure
    ENV["CLOUDFLARE_API_TOKEN"] = old_token if old_token
  end

  def test_dns_sync_upserts_configured_cloudflare_records
    old_token = ENV["CLOUDFLARE_API_TOKEN"]
    ENV["CLOUDFLARE_API_TOKEN"] = "test-token"
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "dns", "sync", "flexday"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "CF_TOKEN='test-token'"
    assert_includes script, "ZONE_NAME='achan.bot'"
    assert_includes script, "tailscale ip -4"
    assert_includes script, "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME"
    assert_includes script, "flexday.tars.achan.bot"
    refute_includes script, "*.flexday.tars.achan.bot"
    assert_empty stderr.string
  ensure
    if old_token
      ENV["CLOUDFLARE_API_TOKEN"] = old_token
    else
      ENV.delete("CLOUDFLARE_API_TOKEN")
    end
  end

  def test_dns_sync_docovia_includes_wildcard_record
    old_token = ENV["CLOUDFLARE_API_TOKEN"]
    ENV["CLOUDFLARE_API_TOKEN"] = "test-token"
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "dns", "sync", "docovia"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "docovia.tars.achan.bot"
    assert_includes script, "*.docovia.tars.achan.bot"
    assert_empty stderr.string
  ensure
    if old_token
      ENV["CLOUDFLARE_API_TOKEN"] = old_token
    else
      ENV.delete("CLOUDFLARE_API_TOKEN")
    end
  end

  def test_cert_issue_uses_acme_dns_challenge_and_installs_to_host_cert_dir
    old_token = ENV["CLOUDFLARE_API_TOKEN"]
    ENV["CLOUDFLARE_API_TOKEN"] = "test-token"
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "cert", "issue", "docovia"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "export CF_Token='test-token'"
    assert_includes script, "--issue --dns dns_cf --server letsencrypt"
    assert_includes script, "-d 'docovia.tars.achan.bot' -d '*.docovia.tars.achan.bot'"
    assert_includes script, "--fullchain-file '/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.crt'"
    assert_includes script, "--key-file '/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key'"
    assert_includes script, "chmod 0600 '/home/bot/.local/share/tesseract/certs/docovia.tars.achan.bot.key'"
    assert_empty stderr.string
  ensure
    if old_token
      ENV["CLOUDFLARE_API_TOKEN"] = old_token
    else
      ENV.delete("CLOUDFLARE_API_TOKEN")
    end
  end

  def test_cert_doctor_checks_installed_certificate
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "cert", "doctor", "docovia"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "echo \"domain=docovia.tars.achan.bot\""
    assert_includes script, "openssl x509"
    assert_empty stderr.string
  end

  def test_unknown_command
    status, _stdout, stderr = run_cli("wat")

    assert_equal 1, status
    assert_includes stderr, "unknown command"
  end

  private

  def pages_list_script(*arguments)
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["pages", "list", *arguments],
      stdout: StringIO.new,
      stderr: StringIO.new,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)
    assert_equal 0, cli.run
    runner.scripts.fetch(0)
  end
end
