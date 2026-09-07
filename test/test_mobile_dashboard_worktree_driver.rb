require "minitest/autorun"
require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class MobileDashboardWorktreeDriverTest < Minitest::Test
  DRIVER = File.expand_path("../libexec/tesseract/worktree-drivers/mobile-dashboard", __dir__)

  def test_start_creates_herdr_workspace_and_wires_api
    with_runtime_fixture do |fixture|
      stdout, stderr, status = run_driver(
        fixture,
        "worktree",
        "start",
        "demo",
        "--api-url",
        "https://api.docovia.example.test:3113/v2"
      )

      assert status.success?, stderr
      assert_includes stdout, "started md/demo"
      assert_includes stdout, "api_url=https://api.docovia.example.test:3113/v2"
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "workspace_id=w7"
      assert_includes stdout, "target=default:md/demo"
      assert_includes stdout, "url=http://localhost:8084"

      log = File.read(fixture.fetch(:herdr_log))
      assert_includes log, "workspace create --cwd #{fixture.fetch(:worktree)} --label md/demo"
      assert_includes log, "tab rename w7:t1 Code"
      assert_includes log, "pane rename w7:p1 Codex"
      assert_includes log, "pane rename w7:p2 Terminal"
      assert_includes log, "tab create --workspace w7"
      assert_includes log, "pane rename w7:p3 Metro"
      assert_includes log,
        "pane run w7:p1 TESSERACT_LIVE_ACTIVITY_APP=mobile-dashboard codex --yolo"
      assert_includes log, "pane run w7:p3 npm start -- --port 8084"

      env = File.read(File.join(fixture.fetch(:worktree), ".env"))
      assert_includes env, "EXPO_PUBLIC_VARIABLE_NAME=docovia\n"
      assert_includes env,
        "EXPO_PUBLIC_DOCOVIA_API_BASE_URL=https://api.docovia.example.test:3113\n"
      assert_includes env, "EXPO_PUBLIC_OAUTH_CLIENT_ID=test-client\n"
      refute_includes env, "EXPO_PUBLIC_API_BASE_URL="
      assert_equal(
        "api_url=https://api.docovia.example.test:3113/v2\nport=8084\n",
        File.read(File.join(fixture.fetch(:worktree), ".tesseract", "runtime"))
      )
    end
  end

  def test_status_reports_legacy_tmux_runtime
    with_runtime_fixture(tmux_running: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "runtime=tmux"
      assert_includes stdout, "tmux_session=mobile_dashboard_demo"
      assert_includes stdout, "legacy_runtime=yes"
    end
  end

  def test_running_workspace_rejects_api_change
    with_runtime_fixture(workspace: true) do |fixture|
      _stdout, stderr, status = run_driver(
        fixture,
        "worktree",
        "start",
        "demo",
        "--api-url",
        "https://api.other.example.test:3114"
      )

      refute status.success?
      assert_includes stderr, "already running with a different API URL"
      refute_includes File.read(fixture.fetch(:herdr_log)), "workspace create"
    end
  end

  def test_stop_closes_herdr_and_legacy_tmux
    with_runtime_fixture(workspace: true, tmux_running: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")

      assert status.success?, stderr
      assert_includes stdout, "stopped md/demo"
      assert_includes stdout, "stopped legacy tmux session mobile_dashboard_demo"
      assert_includes File.read(fixture.fetch(:herdr_log)), "workspace close w7"
      assert_includes File.read(fixture.fetch(:tmux_log)), "kill-session -t =mobile_dashboard_demo"
    end
  end

  private

  def with_runtime_fixture(workspace: false, tmux_running: false)
    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      worktree_root = File.join(directory, "worktrees")
      worktree = File.join(worktree_root, "demo")
      fake_bin = File.join(directory, "bin")
      FileUtils.mkdir_p([
        File.join(main, ".git"),
        File.join(worktree, ".tesseract"),
        File.join(worktree, "node_modules"),
        fake_bin
      ])
      File.write(
        File.join(main, ".env"),
        <<~ENV
          EXPO_PUBLIC_VARIABLE_NAME=docovia
          EXPO_PUBLIC_API_BASE_URL=https://api.old.example.test
          EXPO_PUBLIC_OAUTH_CLIENT_ID=test-client
          PRESERVED_VALUE=yes
        ENV
      )
      package_lock = "{\"lockfileVersion\":3}\n"
      File.write(File.join(worktree, "package-lock.json"), package_lock)
      File.write(
        File.join(worktree, ".tesseract", "package-lock.sha256"),
        "#{Digest::SHA256.hexdigest(package_lock)}\n"
      )
      File.write(
        File.join(worktree, ".tesseract", "runtime"),
        "api_url=https://api.docovia.example.test:3113/v2\nport=8084\n"
      )
      herdr_log = File.join(directory, "herdr.log")
      tmux_log = File.join(directory, "tmux.log")
      FileUtils.touch([herdr_log, tmux_log])
      create_fake_git(fake_bin)
      create_fake_herdr(fake_bin)
      create_fake_tmux(fake_bin)
      create_executable(File.join(fake_bin, "lsof"), "exit 1\n")
      create_executable(File.join(fake_bin, "npm"), "exit 99\n")
      create_executable(File.join(fake_bin, "curl"), "exit 1\n")

      environment = {
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
        "TESSERACT_APP_ID" => "mobile-dashboard",
        "TESSERACT_APP_SHORTHAND" => "md",
        "TESSERACT_MAIN_PATH" => main,
        "TESSERACT_WORKTREE_ROOT" => worktree_root,
        "TESSERACT_PORT_START" => "8081",
        "TESSERACT_PORT_COUNT" => "100",
        "TESSERACT_AGENT_COMMAND" => "codex --yolo",
        "TESSERACT_AGENT_NAME" => "codex",
        "TESSERACT_HERDR_SESSION" => "default",
        "HERDR_LOG" => herdr_log,
        "TMUX_LOG" => tmux_log,
        "TMUX_RUNNING" => tmux_running ? "0" : "1",
        "HERDR_WORKSPACES_JSON" => workspace_list_json(workspace),
        "HERDR_PANES_JSON" => panes_json(worktree)
      }
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

  def create_fake_git(fake_bin)
    create_executable(
      File.join(fake_bin, "git"),
      <<~SH
        case "$*" in
          *"rev-parse --is-inside-work-tree"*) echo true ;;
          *"branch --show-current"*) echo feature/demo ;;
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
          "pane split") printf '%s\n' '{"result":{"pane":{"pane_id":"w7:p2"}}}' ;;
          "pane run"|"pane rename"|"pane report-metadata") printf '%s\n' '{"result":{}}' ;;
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

  def workspace_list_json(workspace)
    workspaces = workspace ? [{"label" => "md/demo", "workspace_id" => "w7"}] : []
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
end
