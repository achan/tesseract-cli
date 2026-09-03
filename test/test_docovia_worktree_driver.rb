require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class DocoviaWorktreeDriverTest < Minitest::Test
  DRIVER = File.expand_path("../libexec/tesseract/worktree-drivers/docovia", __dir__)

  def test_start_creates_docovia_herdr_layout_and_processes
    with_runtime_fixture do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")

      assert status.success?, stderr
      assert_includes stdout, "started doc/demo"
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "session=default"
      assert_includes stdout, "workspace_id=w7"
      assert_includes stdout, "target=default:doc/demo"

      log = File.read(fixture.fetch(:herdr_log))
      assert_includes log, "workspace create --cwd #{fixture.fetch(:worktree)} --label doc/demo"
      assert_includes log, "tab rename w7:t1 Code"
      assert_includes log, "pane rename w7:p1 Codex"
      assert_includes log, "pane rename w7:p2 Terminal"
      assert_includes log, "tab create --workspace w7 --cwd #{fixture.fetch(:worktree)} --label Servers"
      assert_includes log, "pane rename w7:p3 Rails"
      assert_includes log, "pane rename w7:p4 Jobs"
      assert_includes log, "pane rename w7:p5 Webpack"
      assert_includes log, "bundle exec rails s -p 3110"
      assert_includes log, "bundle exec rake jobs:work"
      assert_includes log, "bin/webpack-dev-server"
      assert_includes log, "pane run w7:p1 TESSERACT_LIVE_ACTIVITY_APP=docovia codex --yolo"
    end
  end

  def test_status_reports_herdr_workspace_and_preserves_repository_setup_state
    with_runtime_fixture(workspace: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "registered=yes"
      assert_includes stdout, "setup=complete"
      assert_includes stdout, "seed=complete"
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "workspace_id=w7"
      assert_includes stdout, "target=default:doc/demo"
      assert_equal 1, stdout.scan(/^running=/).length
      assert_equal 1, stdout.scan(/^session=/).length
    end
  end

  def test_status_reports_legacy_tmux_runtime
    with_runtime_fixture(tmux_running: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "runtime=tmux"
      assert_includes stdout, "tmux_session=docovia_demo"
      assert_includes stdout, "legacy_runtime=yes"
    end
  end

  def test_create_and_remove_delegate_repository_lifecycle
    with_runtime_fixture do |fixture|
      _stdout, stderr, status = run_driver(
        fixture,
        "worktree", "create", "demo", "feature/demo"
      )
      assert status.success?, stderr

      _stdout, stderr, status = run_driver(
        fixture,
        "worktree", "remove", "demo", "--force"
      )
      assert status.success?, stderr

      repository_log = File.read(fixture.fetch(:repository_log))
      assert_includes repository_log, "worktree create demo feature/demo"
      assert_includes repository_log, "worktree remove demo --force"
    end
  end

  private

  def with_runtime_fixture(workspace: false, tmux_running: false)
    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      worktree_root = File.join(directory, "worktrees")
      worktree = File.join(worktree_root, "demo")
      fake_bin = File.join(directory, "fake-bin")
      FileUtils.mkdir_p([File.join(main, "bin"), worktree, fake_bin])
      File.write(
        File.join(worktree, ".env.development.local"),
        "PORT=3110\nWEBPACKER_DEV_SERVER_PORT=4110\n"
      )
      FileUtils.touch([
        File.join(worktree, "app.crt"),
        File.join(worktree, "app.key")
      ])

      repository_log = File.join(directory, "repository.log")
      herdr_log = File.join(directory, "herdr.log")
      tmux_log = File.join(directory, "tmux.log")
      FileUtils.touch([repository_log, herdr_log, tmux_log])
      create_repository_adapter(File.join(main, "bin", "tesseract"))
      create_fake_git(fake_bin)
      create_fake_bundle(fake_bin)
      create_fake_herdr(fake_bin)
      create_fake_tmux(fake_bin)

      environment = {
        "PATH" => "#{fake_bin}:#{ENV.fetch("PATH")}",
        "TESSERACT_APP_ID" => "docovia",
        "TESSERACT_APP_SHORTHAND" => "doc",
        "TESSERACT_MAIN_PATH" => main,
        "TESSERACT_WORKTREE_ROOT" => worktree_root,
        "TESSERACT_DOMAIN" => "docovia.example.test",
        "TESSERACT_CERT_PATH" => File.join(worktree, "app.crt"),
        "TESSERACT_KEY_PATH" => File.join(worktree, "app.key"),
        "TESSERACT_AGENT_COMMAND" => "codex --yolo",
        "TESSERACT_AGENT_NAME" => "codex",
        "TESSERACT_HERDR_SESSION" => "default",
        "REPOSITORY_LOG" => repository_log,
        "HERDR_LOG" => herdr_log,
        "TMUX_LOG" => tmux_log,
        "TMUX_RUNNING" => tmux_running ? "0" : "1",
        "HERDR_WORKSPACES_JSON" => workspace_list_json(workspace),
        "HERDR_PANES_JSON" => panes_json(worktree)
      }

      yield(
        environment: environment,
        worktree: worktree,
        repository_log: repository_log,
        herdr_log: herdr_log
      )
    end
  end

  def run_driver(fixture, *arguments)
    Open3.capture3(fixture.fetch(:environment), "bash", DRIVER, *arguments)
  end

  def create_repository_adapter(path)
    create_executable(
      path,
      <<~SH
        printf '%s\n' "$*" >> "$REPOSITORY_LOG"
        if [ "$1 $2" = "worktree status" ]; then
          cat <<'STATUS'
        app=docovia
        slug=demo
        registered=yes
        branch=feature/demo
        port=3110
        url=https://app.docovia.example.test:3110
        setup=complete
        seed=complete
        running=no
        session=docovia_demo
        STATUS
        fi
      SH
    )
  end

  def create_fake_git(directory)
    create_executable(
      File.join(directory, "git"),
      <<~SH
        case "$*" in
          *"rev-parse --is-inside-work-tree"*) echo true ;;
          *) exit 0 ;;
        esac
      SH
    )
  end

  def create_fake_bundle(directory)
    create_executable(File.join(directory, "bundle"), "exit 0\n")
  end

  def create_fake_herdr(directory)
    create_executable(
      File.join(directory, "herdr"),
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
            if printf '%s\n' "$*" | grep -q 'w7:p1'; then pane=w7:p2; else
              count=$(grep -c '^pane split' "$HERDR_LOG")
              [ "$count" -eq 2 ] && pane=w7:p4 || pane=w7:p5
            fi
            printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
            ;;
          "pane run"|"pane rename"|"pane report-metadata") printf '%s\n' '{"result":{"type":"ok"}}' ;;
          *) exit 1 ;;
        esac
      SH
    )
  end

  def create_fake_tmux(directory)
    create_executable(
      File.join(directory, "tmux"),
      <<~SH
        printf '%s\n' "$*" >> "$TMUX_LOG"
        if [ "$1" = has-session ]; then exit "$TMUX_RUNNING"; fi
      SH
    )
  end

  def create_executable(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/usr/bin/env bash\nset -eu\n#{contents}")
    FileUtils.chmod(0o755, path)
  end

  def workspace_list_json(workspace)
    workspaces = workspace ? [{"label" => "doc/demo", "workspace_id" => "w7"}] : []
    JSON.generate("result" => {"workspaces" => workspaces})
  end

  def panes_json(worktree)
    JSON.generate(
      "result" => {
        "panes" => [
          {"pane_id" => "w7:p1", "cwd" => worktree, "agent" => "codex"},
          {"pane_id" => "w7:p2", "cwd" => worktree, "agent" => nil}
        ]
      }
    )
  end
end
