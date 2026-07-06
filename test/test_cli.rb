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

  def test_worktree_start_reads_runtime_files_from_worktree
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "start", "docovia", "demo"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_operator script.index('cd "$WORKTREE_PATH"'), :<, script.index("[ -f .ruby-version ]")
    assert_empty stderr.string
  end

  def test_worktree_create_writes_database_password_for_app
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    service_runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "create", "docovia", "demo"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)
    cli.instance_variable_set(:@service_runner, service_runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "PGUSER=${PGUSER_VALUE}"
    assert_includes script, "SPRUNG_DATABASE_PASSWORD='dev'"
    assert_empty stderr.string
  end

  def test_flexday_setup_uses_configured_node_runtime_and_pnpm
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "app", "setup", "flexday"],
      stdout: stdout,
      stderr: stderr,
      root: File.expand_path("..", __dir__)
    )
    cli.instance_variable_set(:@runner, runner)

    status = cli.run
    script = runner.scripts.fetch(0)

    assert_equal 0, status
    assert_includes script, "CONFIGURED_SPECS='node@20.20.0'"
    assert_includes script, "mise install --quiet $MISE_SPECS"
    assert_includes script, "mise exec $MISE_SPECS -- corepack enable"
    assert_includes script, "mise exec $MISE_SPECS -- corepack prepare pnpm@9 --activate"
    assert_includes script, "mise exec $MISE_SPECS -- pnpm install --frozen-lockfile"
    assert_empty stderr.string
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

  def test_flexday_worktree_create_skips_database_and_writes_next_env
    stdout = StringIO.new
    stderr = StringIO.new
    runner = ScriptCaptureRunner.new
    service_runner = ScriptCaptureRunner.new
    cli = Tesseract::CLI.new(
      ["--host", "tars", "worktree", "create", "flexday", "demo"],
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
    assert_includes script, "export DATABASE_ENABLED='false'"
    assert_includes script, "export MISE_SPECS='node@20.20.0'"
    assert_includes script, "NEXT_PUBLIC_SITE_URL=http://${DOMAIN}:${PORT}"
    assert_includes script, "mise exec $MISE_SPECS -- pnpm install --frozen-lockfile"
    refute_includes script, "docker exec tesseract-postgres"
    assert_empty stderr.string
  end

  def test_flexday_worktree_start_runs_next_without_worker
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
    assert_includes script, "pnpm exec next dev -H 0.0.0.0 -p {port}"
    assert_includes script, "WORKTREE_PATH=$(printf \"%s\\n\" \"$row\" | awk -F '\\t' '{ print $5 }')"
    refute_includes script, "read -r _ PORT REDIS_DB DB_NAME WORKTREE_PATH SESSION"
    assert_includes script, "URL_TEMPLATE='http://{domain}:{port}'"
    assert_includes script, "echo \"url=$URL\""
    assert_includes script, "if [ -n \"$WORKER_COMMAND\" ]; then"
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
