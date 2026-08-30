require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "tesseract/config"
require "tesseract/worktree_drivers"

class WorktreeDriversTest < Minitest::Test
  DRIVER = File.expand_path("../libexec/tesseract/worktree-drivers/signatures", __dir__)

  def test_registry_finds_signatures_driver
    registry = Tesseract::WorktreeDrivers::Registry.new(File.expand_path("..", __dir__))

    assert registry.known?("repository")
    assert registry.known?("git")
    assert registry.central?("signatures")
    assert_equal %w[createdb git herdr jq mise ss], registry.fetch("signatures").required_commands
    assert_raises(Tesseract::WorktreeDrivers::Error) { registry.fetch("missing") }
  end

  def test_signatures_status_reports_stopped_worktree
    with_runtime_fixture do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "registered=yes"
      assert_includes stdout, "branch=feature/demo"
      assert_includes stdout, "port=6204"
      assert_includes stdout, "running=no"
      assert_includes stdout, "runtime=none"
      assert_includes stdout, "target=-"
    end
  end

  def test_signatures_status_reports_herdr_workspace
    with_runtime_fixture(workspace: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "running=yes"
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "session=default"
      assert_includes stdout, "workspace_id=w7"
      assert_includes stdout, "target=default:sig/demo"
    end
  end

  def test_signatures_status_finds_legacy_full_app_workspace_label
    with_runtime_fixture(workspace: true, legacy_workspace: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "workspace_id=w7"
      assert_includes stdout, "target=default:sig/demo"
    end
  end

  def test_signatures_status_reports_legacy_tmux
    with_runtime_fixture(tmux_running: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "runtime=tmux"
      assert_includes stdout, "tmux_session=signatures_demo"
      assert_includes stdout, "legacy_runtime=yes"
    end
  end

  def test_signatures_start_creates_code_and_servers_tabs
    with_runtime_fixture do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")

      assert status.success?, stderr
      assert_includes stdout, "started sig/demo"
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "workspace_id=w7"
      log = File.read(fixture.fetch(:herdr_log))
      assert_includes log,
        "workspace create --cwd #{fixture.fetch(:worktree)} --label sig/demo"
      assert_includes log, "tab rename w7:t1 Code"
      assert_includes log, "pane split --pane w7:p1 --direction right --ratio 0.5"
      assert_includes log, "pane rename w7:p1 Codex"
      assert_includes log, "pane rename w7:p2 Terminal"
      assert_includes log,
        "tab create --workspace w7 --cwd #{fixture.fetch(:worktree)} --label Servers"
      assert_includes log, "pane run w7:p1 TESSERACT_LIVE_ACTIVITY_APP=signatures codex --yolo"
      assert_includes log, "pane run w7:p3 PORT=6204"
      assert_includes log, "bin/dev"
      assert_includes log,
        "pane report-metadata w7:p1 --source tesseract --display-agent codex --token url=https://signatures.example.test:6204"
      assert_includes log,
        "pane report-metadata w7:p2 --source tesseract --token url=https://signatures.example.test:6204"
      assert_includes log,
        "pane report-metadata w7:p3 --source tesseract --token url=https://signatures.example.test:6204"
    end
  end

  def test_signatures_start_rolls_back_partial_herdr_workspace
    with_runtime_fixture(fail_split: true) do |fixture|
      _stdout, _stderr, status = run_driver(fixture, "worktree", "start", "demo")

      refute status.success?
      assert_includes File.read(fixture.fetch(:herdr_log)), "workspace close w7"
    end
  end

  def test_signatures_start_refreshes_url_metadata_for_existing_workspace
    with_runtime_fixture(workspace: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")

      assert status.success?, stderr
      assert_includes stdout, "workspace already running: sig/demo"
      log = File.read(fixture.fetch(:herdr_log))
      refute_includes log, "workspace rename"
      assert_includes log,
        "pane report-metadata w7:p1 --source tesseract --token url=https://signatures.example.test:6204"
      assert_includes log,
        "pane report-metadata w7:p2 --source tesseract --token url=https://signatures.example.test:6204"
      assert_includes log,
        "pane report-metadata w7:p1 --source tesseract --display-agent codex"
      refute_includes log, "workspace create"
    end
  end

  def test_signatures_start_normalizes_an_existing_multiline_workspace_label
    with_runtime_fixture(workspace: true, multiline_workspace: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")

      assert status.success?, stderr
      assert_includes stdout, "workspace already running: sig/demo"
      assert_includes File.read(fixture.fetch(:herdr_log)),
        "workspace rename w7 sig/demo"
    end
  end

  def test_signatures_start_refuses_legacy_tmux_session
    with_runtime_fixture(tmux_running: true) do |fixture|
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")

      refute status.success?
      assert_includes stderr, "stop it before starting Herdr"
      refute_includes File.read(fixture.fetch(:herdr_log)), "workspace create"
    end
  end

  def test_signatures_stop_closes_herdr_and_legacy_tmux
    with_runtime_fixture(workspace: true, tmux_running: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")

      assert status.success?, stderr
      assert_includes stdout, "stopped sig/demo"
      assert_includes stdout, "stopped legacy tmux session signatures_demo"
      assert_includes File.read(fixture.fetch(:herdr_log)), "workspace close w7"
      assert_includes File.read(fixture.fetch(:tmux_log)), "kill-session -t =signatures_demo"
    end
  end

  def test_signatures_create_prepares_central_worktree_state
    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      worktree_root = File.join(directory, "worktrees")
      fake_bin = File.join(directory, "bin")
      FileUtils.mkdir_p([main, fake_bin])
      create_executable(File.join(main, "bin", "rails"), "printf '%s\\n' \"$*\" >> \"$RAILS_LOG\"\n")
      run_command("git", "init", "-b", "main", main)
      run_command("git", "-C", main, "config", "user.email", "test@example.com")
      run_command("git", "-C", main, "config", "user.name", "Test")
      run_command("git", "-C", main, "add", "bin/rails")
      run_command("git", "-C", main, "commit", "-m", "Initial")
      create_executable(File.join(fake_bin, "bundle"), "exit 0\n")
      create_executable(File.join(fake_bin, "createdb"), "printf '%s\\n' \"$*\" >> \"$CREATEDB_LOG\"\n")
      create_executable(File.join(fake_bin, "ss"), "exit 1\n")
      environment = base_environment(
        main: main,
        worktree_root: worktree_root,
        fake_bin: fake_bin,
        directory: directory
      )

      stdout, stderr, status = Open3.capture3(
        environment,
        "bash",
        DRIVER,
        "worktree",
        "create",
        "demo"
      )

      assert status.success?, stderr
      worktree = File.join(worktree_root, "demo")
      assert_includes stdout, "created signatures/demo branch=feature/demo port=6200"
      assert_equal "feature/demo", command_output("git", "-C", worktree, "branch", "--show-current").strip
      development_env = File.read(File.join(worktree, ".env.development.local"))
      assert_includes development_env, "PORT=6200"
      assert_includes development_env, "DB_NAME=signatures_dev_worktree_demo"
      assert_equal 0o600, File.stat(File.join(worktree, ".env.development.local")).mode & 0o777
      assert_includes File.read(environment.fetch("CREATEDB_LOG")), "signatures_dev_worktree_demo"
      assert_includes File.read(environment.fetch("RAILS_LOG")), "db:prepare"
    end
  end

  private

  def with_runtime_fixture(
    workspace: false,
    legacy_workspace: false,
    multiline_workspace: false,
    tmux_running: false,
    fail_split: false
  )
    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      worktree_root = File.join(directory, "worktrees")
      worktree = File.join(worktree_root, "demo")
      fake_bin = File.join(directory, "bin")
      FileUtils.mkdir_p([File.join(main, ".git"), worktree, fake_bin])
      File.write(File.join(worktree, ".env.development.local"), "PORT=6204\n")
      cert = File.join(directory, "signatures.crt")
      key = File.join(directory, "signatures.key")
      FileUtils.touch([cert, key])
      herdr_log = File.join(directory, "herdr.log")
      tmux_log = File.join(directory, "tmux.log")
      FileUtils.touch([herdr_log, tmux_log])
      create_fake_git(fake_bin)
      create_fake_herdr(fake_bin)
      create_fake_tmux(fake_bin)
      create_executable(File.join(fake_bin, "bundle"), "exit 0\n")
      environment = base_environment(
        main: main,
        worktree_root: worktree_root,
        fake_bin: fake_bin,
        directory: directory
      ).merge(
        "TESSERACT_CERT_PATH" => cert,
        "TESSERACT_KEY_PATH" => key,
        "HERDR_LOG" => herdr_log,
        "TMUX_LOG" => tmux_log,
        "TMUX_RUNNING" => tmux_running ? "0" : "1",
        "HERDR_FAIL_SPLIT" => fail_split ? "1" : "0",
        "HERDR_WORKSPACES_JSON" => workspace_list_json(
          workspace,
          legacy: legacy_workspace,
          multiline: multiline_workspace
        ),
        "HERDR_PANES_JSON" => panes_json(worktree)
      )
      yield(
        environment: environment,
        worktree: worktree,
        herdr_log: herdr_log,
        tmux_log: tmux_log
      )
    end
  end

  def run_driver(fixture, *arguments)
    Open3.capture3(fixture.fetch(:environment), "bash", DRIVER, *arguments)
  end

  def base_environment(main:, worktree_root:, fake_bin:, directory:)
    {
      "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
      "TESSERACT_APP_ID" => "signatures",
      "TESSERACT_APP_SHORTHAND" => "sig",
      "TESSERACT_MAIN_PATH" => main,
      "TESSERACT_WORKTREE_ROOT" => worktree_root,
      "TESSERACT_DOMAIN" => "signatures.example.test",
      "TESSERACT_PORT_START" => "6200",
      "TESSERACT_PORT_COUNT" => "100",
      "TESSERACT_DATABASE_PREFIX" => "signatures_dev_worktree",
      "TESSERACT_CERT_PATH" => File.join(directory, "signatures.crt"),
      "TESSERACT_KEY_PATH" => File.join(directory, "signatures.key"),
      "TESSERACT_PGHOST" => "127.0.0.1",
      "TESSERACT_PGUSER" => "bot",
      "TESSERACT_PGPASSWORD" => "dev",
      "TESSERACT_WEB_COMMAND" => "bin/dev",
      "TESSERACT_AGENT_COMMAND" => "codex --yolo",
      "TESSERACT_AGENT_NAME" => "codex",
      "TESSERACT_HERDR_SESSION" => "default",
      "CREATEDB_LOG" => File.join(directory, "createdb.log"),
      "RAILS_LOG" => File.join(directory, "rails.log")
    }
  end

  def create_fake_git(fake_bin)
    create_executable(
      File.join(fake_bin, "git"),
      <<~SH
        case "$*" in
          *"rev-parse --is-inside-work-tree"*) echo true ;;
          *"branch --show-current"*) echo feature/demo ;;
          *"status --porcelain"*) : ;;
          *) exit 0 ;;
        esac
      SH
    )
  end

  def create_fake_herdr(fake_bin)
    create_executable(
      File.join(fake_bin, "herdr"),
      <<~SH
        printf '%s\n' "$*" >> "$HERDR_LOG"
        case "$1 $2" in
          "workspace list") printf '%s\n' "$HERDR_WORKSPACES_JSON" ;;
          "workspace create") printf '%s\n' '{"result":{"workspace":{"workspace_id":"w7"},"tab":{"tab_id":"w7:t1"},"root_pane":{"pane_id":"w7:p1"}}}' ;;
          "workspace close") printf '%s\n' '{"result":{"type":"workspace_closed"}}' ;;
          "workspace rename") printf '%s\n' '{"result":{"type":"workspace_renamed"}}' ;;
          "tab rename") printf '%s\n' '{"result":{"type":"tab_renamed"}}' ;;
          "tab create") printf '%s\n' '{"result":{"tab":{"tab_id":"w7:t2"},"root_pane":{"pane_id":"w7:p3"}}}' ;;
          "pane list") printf '%s\n' "$HERDR_PANES_JSON" ;;
          "pane split")
            [ "$HERDR_FAIL_SPLIT" = 0 ] || exit 1
            printf '%s\n' '{"result":{"pane":{"pane_id":"w7:p2"}}}'
            ;;
          "pane run") printf '%s\n' '{"result":{"type":"pane_run"}}' ;;
          "pane rename") printf '%s\n' '{"result":{"type":"pane_renamed"}}' ;;
          "pane report-metadata") printf '%s\n' '{"result":{"type":"pane_metadata_reported"}}' ;;
          *) exit 1 ;;
        esac
      SH
    )
  end

  def create_fake_tmux(fake_bin)
    create_executable(
      File.join(fake_bin, "tmux"),
      <<~SH
        printf '%s\n' "$*" >> "$TMUX_LOG"
        if [ "$1" = has-session ]; then
          exit "$TMUX_RUNNING"
        fi
      SH
    )
  end

  def workspace_list_json(workspace, legacy: false, multiline: false)
    label = if legacy
      "signatures/demo"
    elsif multiline
      "sig/demo\nfeature/demo"
    else
      "sig/demo"
    end
    workspaces = workspace ? [{"label" => label, "workspace_id" => "w7"}] : []
    JSON.generate("result" => {"workspaces" => workspaces})
  end

  def panes_json(worktree)
    JSON.generate(
      "result" => {
        "panes" => [
          {"pane_id" => "w7:p1", "cwd" => worktree, "agent" => "codex"},
          {"pane_id" => "w7:p2", "cwd" => worktree}
        ]
      }
    )
  end

  def create_executable(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n#{body}")
    FileUtils.chmod(0o755, path)
  end

  def run_command(*command)
    _stdout, stderr, status = Open3.capture3(*command)
    assert status.success?, stderr
  end

  def command_output(*command)
    stdout, stderr, status = Open3.capture3(*command)
    assert status.success?, stderr
    stdout
  end
end
