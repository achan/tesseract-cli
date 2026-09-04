require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class SprungWorktreeDriverTest < Minitest::Test
  DRIVER = File.expand_path("../libexec/tesseract/worktree-drivers/sprung", __dir__)

  def test_start_creates_sprung_herdr_layout_and_processes
    with_runtime_fixture do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")

      assert status.success?, stderr
      assert_includes stdout, "started spr/demo"
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "session=default"
      assert_includes stdout, "workspace_id=w7"
      assert_includes stdout, "target=default:spr/demo"
      assert_includes stdout, "url=https://app.docovia.example.test:3110"
      assert_includes stdout, "url_alias[smilesnap.example.test]=https://app.smilesnap.example.test:3110"

      log = File.read(fixture.fetch(:herdr_log))
      assert_includes log, "workspace create --cwd #{fixture.fetch(:worktree)} --label spr/demo"
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
      assert_includes log, "pane run w7:p1 TESSERACT_LIVE_ACTIVITY_APP=sprung codex --yolo"

      env = File.read(File.join(fixture.fetch(:worktree), ".env.development.local"))
      assert_includes env, "APP_NAME=Docovia\n"
      assert_includes env, "APP_DOMAIN=docovia.example.test\n"
      assert_includes env, "DASHBOARD_DOMAIN=app.docovia.example.test\n"
      assert_includes env, "WEBSITE_URL=https://app.docovia.example.test:3110\n"
      assert_includes env, "API_URL=https://api.docovia.example.test:3110\n"
      assert_includes env, "S3_BUCKET_NAME_PUBLIC=docovia-development-public\n"
      assert_includes env, "CDN_URL=//s3.us-east-2.amazonaws.com/docovia-public\n"
      assert_includes env, "THEME_GRADIENT_END_COLOR=\"#3899c2\"\n"
      assert_includes env, "THEME_GRADIENT_START_COLOR=\"#09937e\"\n"
      assert_includes env, "THEME_TOP_BAR_COLOR=\"#144c5d\"\n"
      assert_includes env, "PORT=3110\n"
      assert_includes env, "DATABASE_URL=postgres://bot:dev@localhost/sprung_demo\n"
      assert_includes env, "REDIS_URL=redis://localhost:6379/42\n"
      assert_includes env, "CUSTOM_VALUE=preserved\n"
    end
  end

  def test_smilesnap_start_writes_smilesnap_runtime_configuration
    with_runtime_fixture do |fixture|
      environment = fixture.fetch(:environment).merge(
        "TESSERACT_REQUESTED_APP_NAME" => "smilesnap",
        "TESSERACT_RUNTIME_DOMAIN" => "smilesnap.example.test",
        "TESSERACT_RUNTIME_APP_NAME" => "SmileSnap",
        "TESSERACT_S3_BUCKET_NAME_PUBLIC" => "smilesnap-development-public",
        "TESSERACT_CDN_BUCKET" => "smilesnap-public",
        "TESSERACT_THEME_GRADIENT_END_COLOR" => "#57c2e6",
        "TESSERACT_THEME_GRADIENT_START_COLOR" => "#327aba",
        "TESSERACT_THEME_TOP_BAR_COLOR" => "#327aba"
      )

      _stdout, stderr, status = Open3.capture3(environment, "bash", DRIVER, "worktree", "start", "demo")

      assert status.success?, stderr
      env = File.read(File.join(fixture.fetch(:worktree), ".env.development.local"))
      assert_includes env, "APP_NAME=SmileSnap\n"
      assert_includes env, "APP_DOMAIN=smilesnap.example.test\n"
      assert_includes env, "DASHBOARD_DOMAIN=app.smilesnap.example.test\n"
      assert_includes env, "WEBSITE_URL=https://app.smilesnap.example.test:3110\n"
      assert_includes env, "API_URL=https://api.smilesnap.example.test:3110\n"
      assert_includes env, "S3_BUCKET_NAME_PUBLIC=smilesnap-development-public\n"
      assert_includes env, "CDN_URL=//s3.us-east-2.amazonaws.com/smilesnap-public\n"
      assert_includes env, "THEME_GRADIENT_END_COLOR=\"#57c2e6\"\n"
      assert_includes env, "THEME_GRADIENT_START_COLOR=\"#327aba\"\n"
      assert_includes env, "THEME_TOP_BAR_COLOR=\"#327aba\"\n"
    end
  end

  def test_stopped_worktree_can_switch_runtime_configuration
    with_runtime_fixture do |fixture|
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr

      smile_environment = fixture.fetch(:environment).merge(
        "TESSERACT_REQUESTED_APP_NAME" => "smilesnap",
        "TESSERACT_RUNTIME_DOMAIN" => "smilesnap.example.test",
        "TESSERACT_RUNTIME_APP_NAME" => "SmileSnap",
        "TESSERACT_S3_BUCKET_NAME_PUBLIC" => "smilesnap-development-public",
        "TESSERACT_CDN_BUCKET" => "smilesnap-public",
        "TESSERACT_THEME_GRADIENT_END_COLOR" => "#57c2e6",
        "TESSERACT_THEME_GRADIENT_START_COLOR" => "#327aba",
        "TESSERACT_THEME_TOP_BAR_COLOR" => "#327aba"
      )
      _stdout, stderr, status = Open3.capture3(smile_environment, "bash", DRIVER, "worktree", "start", "demo")

      assert status.success?, stderr
      env = File.read(File.join(fixture.fetch(:worktree), ".env.development.local"))
      assert_includes env, "APP_NAME=SmileSnap\n"
      assert_includes env, "APP_DOMAIN=smilesnap.example.test\n"
      assert_includes env, "S3_BUCKET_NAME_PUBLIC=smilesnap-development-public\n"
      assert_includes env, "CDN_URL=//s3.us-east-2.amazonaws.com/smilesnap-public\n"
      assert_includes env, "THEME_GRADIENT_END_COLOR=\"#57c2e6\"\n"
      assert_equal 1, env.scan(/^APP_DOMAIN=/).length
      assert_equal 1, env.scan(/^S3_BUCKET_NAME_PUBLIC=/).length
    end
  end

  def test_running_worktree_rejects_runtime_switch_without_modifying_env
    with_runtime_fixture(workspace: true) do |fixture|
      env_file = File.join(fixture.fetch(:worktree), ".env.development.local")
      before = File.read(env_file)
      smile_environment = fixture.fetch(:environment).merge(
        "TESSERACT_REQUESTED_APP_NAME" => "smilesnap",
        "TESSERACT_RUNTIME_DOMAIN" => "smilesnap.example.test",
        "TESSERACT_RUNTIME_APP_NAME" => "SmileSnap",
        "TESSERACT_S3_BUCKET_NAME_PUBLIC" => "smilesnap-development-public",
        "TESSERACT_CDN_BUCKET" => "smilesnap-public",
        "TESSERACT_THEME_GRADIENT_END_COLOR" => "#57c2e6",
        "TESSERACT_THEME_GRADIENT_START_COLOR" => "#327aba",
        "TESSERACT_THEME_TOP_BAR_COLOR" => "#327aba"
      )

      _stdout, stderr, status = Open3.capture3(smile_environment, "bash", DRIVER, "worktree", "start", "demo")

      refute status.success?
      assert_includes stderr, "already running with a different runtime configuration"
      assert_includes stderr, "tesseract worktree stop smilesnap demo"
      assert_includes stderr, "tesseract worktree start smilesnap demo"
      assert_equal before, File.read(env_file)
    end
  end

  def test_status_reports_herdr_workspace_and_preserves_repository_setup_state
    with_runtime_fixture(workspace: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")

      assert status.success?, stderr
      assert_includes stdout, "registered=yes"
      assert_includes stdout, "setup=complete"
      assert_includes stdout, "seed=complete"
      assert_includes stdout, "app=sprung"
      refute_includes stdout, "app=docovia"
      assert_includes stdout, "url=https://app.docovia.example.test:3110"
      assert_includes stdout, "url_alias[smilesnap.example.test]=https://app.smilesnap.example.test:3110"
      assert_includes stdout, "runtime=herdr"
      assert_includes stdout, "workspace_id=w7"
      assert_includes stdout, "target=default:spr/demo"
      assert_equal 1, stdout.scan(/^running=/).length
      assert_equal 1, stdout.scan(/^session=/).length
    end
  end

  def test_start_renames_legacy_doc_workspace_to_sprung_identity
    with_runtime_fixture(workspace: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")

      assert status.success?, stderr
      assert_includes stdout, "workspace already running: spr/demo"
      assert_includes File.read(fixture.fetch(:herdr_log)), "workspace rename w7 spr/demo"
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

  def test_stop_closes_legacy_doc_workspace_and_docovia_tmux_session
    with_runtime_fixture(workspace: true, tmux_running: true) do |fixture|
      stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")

      assert status.success?, stderr
      assert_includes stdout, "stopped spr/demo"
      assert_includes stdout, "stopped legacy tmux session docovia_demo"
      assert_includes File.read(fixture.fetch(:herdr_log)), "workspace close w7"
      assert_includes File.read(fixture.fetch(:tmux_log)), "kill-session -t =docovia_demo"
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
        <<~ENV
          PORT=3110
          WEBPACKER_DEV_SERVER_PORT=4110
          APP_NAME=Docovia
          APP_DOMAIN=docovia.example.test
          DASHBOARD_DOMAIN=app.docovia.example.test
          WEBSITE_URL=https://app.docovia.example.test:3110
          API_URL=https://api.docovia.example.test:3110
          S3_BUCKET_NAME_PUBLIC=docovia-development-public
          CDN_URL=//s3.us-east-2.amazonaws.com/docovia-public
          THEME_GRADIENT_END_COLOR="#3899c2"
          THEME_GRADIENT_START_COLOR="#09937e"
          THEME_TOP_BAR_COLOR="#144c5d"
          DATABASE_URL=postgres://bot:dev@localhost/sprung_demo
          REDIS_URL=redis://localhost:6379/42
          CUSTOM_VALUE=preserved
        ENV
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
        "TESSERACT_APP_ID" => "sprung",
        "TESSERACT_REQUESTED_APP_NAME" => "sprung",
        "TESSERACT_APP_SHORTHAND" => "spr",
        "TESSERACT_MAIN_PATH" => main,
        "TESSERACT_WORKTREE_ROOT" => worktree_root,
        "TESSERACT_DOMAIN" => "docovia.example.test",
        "TESSERACT_DOMAIN_ALIASES" => "smilesnap.example.test",
        "TESSERACT_RUNTIME_DOMAIN" => "docovia.example.test",
        "TESSERACT_RUNTIME_APP_NAME" => "Docovia",
        "TESSERACT_S3_BUCKET_NAME_PUBLIC" => "docovia-development-public",
        "TESSERACT_CDN_BUCKET" => "docovia-public",
        "TESSERACT_THEME_GRADIENT_END_COLOR" => "#3899c2",
        "TESSERACT_THEME_GRADIENT_START_COLOR" => "#09937e",
        "TESSERACT_THEME_TOP_BAR_COLOR" => "#144c5d",
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
        herdr_log: herdr_log,
        tmux_log: tmux_log
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
