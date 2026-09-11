require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class TesseractWebWorktreeDriverTest < Minitest::Test
  DRIVER = File.expand_path("../libexec/tesseract/worktree-drivers/tesseract-web", __dir__)

  def test_start_creates_herdr_workspace_and_all_services
    with_runtime_fixture do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")

      assert status.success?, stderr
      assert_includes stdout, "started tess/demo"
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "workspace_id=w7"
      assert_includes stdout, "target=default:tess/demo"
      assert_includes stdout, "url=https://tesseract-web.example.test:6104"

      log = File.read(fixture.fetch(:herdr_log))
      assert_includes log, "workspace create --cwd #{fixture.fetch(:worktree)} --label tess/demo"
      assert_includes log, "tab rename w7:t1 Code"
      assert_includes log, "pane rename w7:p1 Codex"
      assert_includes log, "pane rename w7:p2 Terminal"
      assert_includes log, "tab create --workspace w7"
      assert_includes log, "pane rename w7:p3 Rails"
      assert_includes log, "pane rename w7:p4 Jobs"
      assert_includes log, "pane rename w7:p5 Tailwind"
      assert_includes log, "pane run w7:p1 TESSERACT_LIVE_ACTIVITY_APP=tesseract-web codex --yolo"
      assert_includes log, "bin/rails server -p 6104"
      assert_includes log, "bin/jobs"
      assert_includes log, "bin/rails tailwindcss:watch"
      assert_includes log, "pane report-metadata w7:p1 --source tesseract --display-agent codex"
    end
  end

  def test_status_reports_legacy_tmux_runtime
    with_runtime_fixture(tmux_running: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "runtime=tmux"
      assert_includes stdout, "tmux_session=tesseract_web_demo"
      assert_includes stdout, "legacy_runtime=yes"
    end
  end

  def test_stop_closes_herdr_and_legacy_tmux
    with_runtime_fixture(workspace: true, tmux_running: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")

      assert status.success?, stderr
      assert_includes stdout, "stopped tess/demo"
      assert_includes stdout, "stopped legacy tmux session tesseract_web_demo"
      assert_includes File.read(fixture.fetch(:herdr_log)), "workspace close w7"
      assert_includes File.read(fixture.fetch(:tmux_log)), "kill-session -t =tesseract_web_demo"
    end
  end

  private

  def with_runtime_fixture(workspace: false, tmux_running: false)
    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      worktree_root = File.join(directory, "worktrees")
      worktree = File.join(worktree_root, "demo")
      fake_bin = File.join(directory, "bin")
      FileUtils.mkdir_p([File.join(main, ".git"), worktree, fake_bin])
      File.write(File.join(worktree, ".env.development.local"), "PORT=6104\n")
      File.write(File.join(worktree, ".ruby-version"), "3.3.0\n")
      cert = File.join(directory, "tesseract-web.crt")
      key = File.join(directory, "tesseract-web.key")
      FileUtils.touch([cert, key])
      herdr_log = File.join(directory, "herdr.log")
      tmux_log = File.join(directory, "tmux.log")
      FileUtils.touch([herdr_log, tmux_log])
      create_fake_git(fake_bin)
      create_fake_herdr(fake_bin)
      create_fake_tmux(fake_bin)
      create_executable(File.join(fake_bin, "mise"), "exit 0\n")

      environment = {
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
        "TESSERACT_APP_ID" => "tesseract-web",
        "TESSERACT_APP_SHORTHAND" => "tess",
        "TESSERACT_MAIN_PATH" => main,
        "TESSERACT_WORKTREE_ROOT" => worktree_root,
        "TESSERACT_DOMAIN" => "tesseract-web.example.test",
        "TESSERACT_CERT_PATH" => cert,
        "TESSERACT_KEY_PATH" => key,
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
      <<~'SH'
        printf '%s\n' "$*" >> "$HERDR_LOG"
        case "$1 $2" in
          "workspace list") printf '%s\n' "$HERDR_WORKSPACES_JSON" ;;
          "workspace create") printf '%s\n' '{"result":{"workspace":{"workspace_id":"w7"},"tab":{"tab_id":"w7:t1"},"root_pane":{"pane_id":"w7:p1"}}}' ;;
          "workspace close") printf '%s\n' '{"result":{"type":"workspace_closed"}}' ;;
          "tab rename") printf '%s\n' '{"result":{"type":"tab_renamed"}}' ;;
          "tab create") printf '%s\n' '{"result":{"tab":{"tab_id":"w7:t2"},"root_pane":{"pane_id":"w7:p3"}}}' ;;
          "pane list") printf '%s\n' "$HERDR_PANES_JSON" ;;
          "pane split")
            case "$*" in
              *"--pane w7:p1"*) pane_id=w7:p2 ;;
              *"--pane w7:p3"*) pane_id=w7:p4 ;;
              *"--pane w7:p4"*) pane_id=w7:p5 ;;
              *) exit 1 ;;
            esac
            printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane_id"
            ;;
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
    workspaces = workspace ? [{"label" => "tess/demo", "workspace_id" => "w7"}] : []
    JSON.generate("result" => {"workspaces" => workspaces})
  end

  def panes_json(worktree)
    JSON.generate(
      "result" => {
        "panes" => (1..5).map do |number|
          pane = {"pane_id" => "w7:p#{number}", "cwd" => worktree}
          pane["agent"] = "codex" if number == 1
          pane
        end
      }
    )
  end

  def create_executable(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n#{body}")
    FileUtils.chmod(0o755, path)
  end
end
