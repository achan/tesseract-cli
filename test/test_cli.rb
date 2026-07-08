require "minitest/autorun"
require "stringio"

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
    assert_empty stderr
  end

  def test_app_list
    status, stdout, stderr = run_cli("--host", "local", "app", "list")

    assert_equal 0, status
    assert_includes stdout, "docovia"
    assert_includes stdout, "flexday"
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
    assert_includes script, "APP"
    assert_includes script, "WORKTREE"
    assert_includes script, "URL"
    assert_includes script, "/home/bot/repos/sprung-app"
    assert_includes script, "/home/bot/repos/flexday"
    assert_includes script, "git -C \"$main_path\" worktree list --porcelain"
    assert_includes script, "\"$main_path/bin/tesseract\" worktree status \"$slug\""
    assert_includes script, "running="
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
    assert_includes script, "exec tmux attach -t '\\''docovia_exam_viewer_optimization'\\''"
    refute_includes script, "worktree status"
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
end
