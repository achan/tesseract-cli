require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "timeout"

class SprungWorktreeDriverTest < Minitest::Test
  DRIVER = File.expand_path("../libexec/tesseract/worktree-drivers/sprung", __dir__)

  def test_start_creates_layout_and_starts_code_before_preparation
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
      assert_includes log, "pane rename w7:p3 Setup"
      assert_includes log, "pane rename w7:p4 Jobs"
      assert_includes log, "pane rename w7:p5 Webpack"
      refute_includes log, "pane run w7:p4"
      refute_includes log, "pane run w7:p5"
      assert_empty File.read(fixture.fetch(:process_log))
      assert_operator log.index("pane run w7:p1"), :<, log.index("tab create")
      runner = File.read(File.join(fixture.fetch(:worktree), "log/.tesseract-active-run")).strip
      assert_equal 0o700, File.stat(runner).mode & 0o777
      assert_includes log, "pane run w7:p3 bash #{runner}"
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

      _stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")
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

  def test_status_reports_herdr_workspace_and_reads_existing_setup_state
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

  def test_create_and_remove_do_not_need_repository_adapter
    with_runtime_fixture do |fixture|
      FileUtils.rm_f(File.join(fixture.fetch(:main), "bin/tesseract"))
      stdout, stderr, status = run_driver(fixture, "worktree", "create", "fresh", "feature/fresh")
      assert status.success?, stderr
      assert_includes stdout, "setup=pending"
      assert_includes stdout, "seed=pending"
      path = File.join(fixture.fetch(:root), "fresh")
      env = File.read(File.join(path, ".env.development.local"))
      assert_includes env, "PORT=3101\n"
      assert_includes env, "DATABASE_NAME=sprung_dev_worktree_fresh\n"
      assert_includes env, "REDIS_URL=redis://127.0.0.1:6379/1\n"
      assert_includes env, "PGUSER=bot\n"
      assert_includes env, "APP_NAME=Docovia\n"
      assert_includes File.read(File.join(path, ".env.test.local")), "VARIABLE_NAME=sprung_dev_worktree_fresh"
      assert_equal 0o600, File.stat(File.join(path, ".env.development.local")).mode & 0o777
      assert_equal File.join(fixture.fetch(:main), ".env.local"), File.readlink(File.join(path, ".env.local"))
      assert_empty File.read(fixture.fetch(:process_log))
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "fresh")
      assert status.success?, stderr
      assert_includes stdout, "branch=feature/fresh"
      assert_includes stdout, "seed=pending"
      _stdout, stderr, status = run_driver(fixture, "worktree", "remove", "fresh")
      assert status.success?, stderr
      refute_path_exists path
      assert_includes File.read(fixture.fetch(:process_log)), "dropdb --if-exists sprung_dev_worktree_fresh"
    end
  end

  def test_code_is_available_while_seed_runs_and_servers_wait_for_success
    with_runtime_fixture(execute_setup: true, pending: true) do |fixture|
      gate = File.join(fixture.fetch(:directory), "seed-gate")
      fixture.fetch(:environment)["SEED_GATE"] = gate
      stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      assert_includes stdout, "workspace_id=w7"
      wait_until { File.exist?("#{gate}.started") }
      log = File.read(fixture.fetch(:herdr_log))
      assert_includes log, "pane run w7:p1"
      assert_includes log, "pane rename w7:p3 Setup"
      refute_includes log, "pane run w7:p4"
      refute_includes log, "pane run w7:p5"
      refute_includes File.read(fixture.fetch(:process_log)), "bundle exec rails s"
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")
      assert status.success?, stderr
      assert_includes stdout, "setup=complete"
      assert_includes stdout, "seed=running"
      assert_includes stdout, "runtime=herdr"
      FileUtils.touch(gate)
      wait_for_worker(fixture, 0)
      log = File.read(fixture.fetch(:herdr_log))
      assert_includes log, "pane rename w7:p3 Rails"
      assert_includes log, "bundle exec rake jobs:work"
      assert_includes log, "bin/webpack-dev-server"
      assert_equal 1, log.scan(/^pane run w7:p4 /).length
      assert_equal 1, log.scan(/^pane run w7:p5 /).length
      refute_match(/^(workspace|tab|pane) focus /, log)
      assert_includes File.read(fixture.fetch(:process_log)), "bundle exec rails s -p 3110"
      assert_includes File.read(File.join(fixture.fetch(:worktree), "log/tesseract-seed.log")), "seed completed"
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")
      assert status.success?, stderr
      assert_includes stdout, "seed=complete"
    end
  end

  def test_seed_failure_preserves_code_and_requires_stop_start_to_retry
    with_runtime_fixture(execute_setup: true, pending: true) do |fixture|
      fixture.fetch(:environment)["SEED_EXIT_STATUS"] = "7"
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      wait_for_worker(fixture, 7)
      log = File.read(fixture.fetch(:herdr_log))
      refute_includes log, "workspace close"
      refute_includes log, "pane run w7:p4"
      assert_includes log, "pane rename w7:p3 Setup failed"
      assert_includes File.read(fixture.fetch(:worker_log)), "tesseract worktree stop sprung demo"
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")
      assert status.success?, stderr
      assert_includes stdout, "seed=failed"
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      assert_equal 1, File.read(fixture.fetch(:herdr_log)).scan(/^pane run w7:p3 /).length
      _stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")
      assert status.success?, stderr
      fixture.fetch(:environment).delete("SEED_EXIT_STATUS")
      FileUtils.rm_f(fixture.fetch(:worker_result))
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      wait_for_worker(fixture, 0)
      assert_includes File.read(fixture.fetch(:process_log)), "bundle exec rails s"
    end
  end

  def test_dependency_failure_prevents_seeding_and_server_launch
    with_runtime_fixture(execute_setup: true, pending: true) do |fixture|
      fixture.fetch(:environment).merge!("BUNDLE_CHECK_STATUS" => "1", "BUNDLE_INSTALL_STATUS" => "9")
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      wait_for_worker(fixture, 9)
      refute_includes File.read(fixture.fetch(:process_log)), "rails runner -"
      refute_includes File.read(fixture.fetch(:herdr_log)), "pane run w7:p4"
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")
      assert status.success?, stderr
      assert_includes stdout, "setup=failed"
      assert_includes stdout, "seed=pending"
    end
  end

  def test_completed_worktree_skips_seeding
    with_runtime_fixture(execute_setup: true) do |fixture|
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      wait_for_worker(fixture, 0)
      log = File.read(fixture.fetch(:process_log))
      refute_includes log, "rails runner -"
      assert_includes log, "bundle check"
      assert_includes log, "bundle exec rails s"
      assert_empty File.read(fixture.fetch(:repository_log))
    end
  end

  def test_stop_cancels_seed_and_prevents_late_server_launch
    with_runtime_fixture(execute_setup: true, pending: true) do |fixture|
      gate = File.join(fixture.fetch(:directory), "seed-gate")
      fixture.fetch(:environment)["SEED_GATE"] = gate
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      wait_until { File.exist?("#{gate}.started") }
      _stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")
      assert status.success?, stderr
      wait_for_worker(fixture, 143)
      FileUtils.touch(gate)
      log = File.read(fixture.fetch(:process_log))
      assert_includes log, "seed cancelled"
      refute_includes log, "bundle exec rails s"
      refute_includes File.read(fixture.fetch(:herdr_log)), "pane run w7:p4"
      stdout, stderr, status = run_driver(fixture, "worktree", "status", "demo")
      assert status.success?, stderr
      assert_includes stdout, "seed=failed"
      assert_includes stdout, "running=no"
    end
  end

  def test_remove_refuses_dirty_worktree_without_force
    with_runtime_fixture do |fixture|
      File.write(File.join(fixture.fetch(:worktree), "unfinished.txt"), "keep me")
      _stdout, stderr, status = run_driver(fixture, "worktree", "remove", "demo")
      refute status.success?
      assert_includes stderr, "uncommitted changes"
      assert_path_exists File.join(fixture.fetch(:worktree), "unfinished.txt")
      assert_empty File.read(fixture.fetch(:process_log))
      _stdout, stderr, status = run_driver(fixture, "worktree", "remove", "demo", "--force")
      assert status.success?, stderr
      refute_path_exists fixture.fetch(:worktree)
    end
  end

  def test_prepare_uses_rails_seed_loader_once_for_new_and_partially_seeded_databases
    with_runtime_fixture(execute_setup: true, pending: true) do |fixture|
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      wait_for_worker(fixture, 0)
      preparation = File.read(fixture.fetch(:environment).fetch("PREPARE_SCRIPT"))
      harness = <<~'RUBY'
        $LOADED_FEATURES << "active_record/tasks/database_tasks.rb"
        module ActiveRecord
          module Tasks
            class DatabaseTasks
              class << self
                attr_accessor :seed_loader, :count
                def prepare_all
                  load_seed if ENV["INITIAL_SEED"] == "1"
                end
                def load_seed
                  seed_loader.load_seed
                end
              end
              self.count = 0
              self.seed_loader = Object.new
              seed_loader.define_singleton_method(:load_seed) do
                DatabaseTasks.count += 1
              end
            end
          end
        end
      RUBY
      %w[0 1].each do |initial_seed|
        stdout, stderr, status = Open3.capture3(
          {"INITIAL_SEED" => initial_seed}, "ruby", "-e",
          harness + preparation + "\nputs ActiveRecord::Tasks::DatabaseTasks.count"
        )
        assert status.success?, stderr
        assert_equal "1", stdout.strip
      end
    end
  end

  def test_waits_for_legacy_seed_without_starting_a_duplicate
    with_runtime_fixture(execute_setup: true, pending: true) do |fixture|
      path = fixture.fetch(:worktree)
      legacy_script = File.join(fixture.fetch(:directory), "legacy-seed")
      gate = File.join(fixture.fetch(:directory), "legacy-gate")
      create_executable(legacy_script, <<~'SH')
        printf '%s\n' "$$" > "$LEGACY_PATH/.tesseract-seed.pid"
        printf 'status=running\n' > "$LEGACY_PATH/.tesseract-seed.status"
        mkdir -p "$LEGACY_PATH/log"
        echo 'legacy seed output' > "$LEGACY_PATH/log/tesseract-seed.log"
        while [ ! -f "$LEGACY_GATE" ]; do sleep 0.05; done
        printf 'status=complete\n' > "$LEGACY_PATH/.tesseract-seed.status"
        rm "$LEGACY_PATH/.tesseract-seed.pid"
      SH
      pid = Process.spawn({"LEGACY_PATH" => path, "LEGACY_GATE" => gate}, legacy_script)
      begin
        wait_until { File.exist?(File.join(path, ".tesseract-seed.pid")) }
        _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
        assert status.success?, stderr
        wait_until { File.read(fixture.fetch(:worker_log)).include?("legacy seed output") }
        assert_empty File.read(fixture.fetch(:process_log))
        refute_includes File.read(fixture.fetch(:herdr_log)), "pane run w7:p4"
        FileUtils.touch(gate)
        Process.wait(pid)
        pid = nil
        wait_for_worker(fixture, 0)
        refute_includes File.read(fixture.fetch(:process_log)), "rails runner -"
        assert_includes File.read(fixture.fetch(:process_log)), "bundle exec rails s"
      ensure
        if pid
          Process.kill("TERM", pid) rescue Errno::ESRCH
          Process.wait(pid) rescue Errno::ECHILD
        end
      end
    end
  end

  def test_create_reserves_both_server_ports_and_preserves_existing_branches
    with_runtime_fixture do |fixture|
      fake_lsof = File.join(fixture.fetch(:directory), "fake-bin/lsof")
      create_executable(fake_lsof, <<~'SH')
        case "$*" in *-iTCP:4101*) exit 0 ;; *) exit 1 ;; esac
      SH
      git("-C", fixture.fetch(:main), "branch", "existing")
      before = git("-C", fixture.fetch(:main), "rev-parse", "existing").strip
      stdout, stderr, status = run_driver(fixture, "worktree", "create", "fresh", "existing")
      assert status.success?, stderr
      assert_includes stdout, "port=3102"
      assert_equal before, git("-C", File.join(fixture.fetch(:root), "fresh"), "rev-parse", "HEAD").strip
      stdout, stderr, status = run_driver(fixture, "worktree", "create", "second")
      assert status.success?, stderr
      assert_includes stdout, "port=3103"
      assert_empty File.read(fixture.fetch(:repository_log))
      assert_empty File.read(fixture.fetch(:process_log))
    end
  end

  def test_asset_build_failure_keeps_code_open_and_stops_before_database_preparation
    with_runtime_fixture(execute_setup: true, pending: true) do |fixture|
      path = fixture.fetch(:worktree)
      File.write(File.join(path, "package.json"), "{}")
      File.write(File.join(path, "yarn.lock"), "fixture")
      create_executable(File.join(path, "bin/yarn"), 'printf "yarn %s\n" "$*" >> "$PROCESS_LOG"')
      create_executable(File.join(path, "bin/build"), 'echo "asset build failed"; exit 12')
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      wait_for_worker(fixture, 12)
      assert_includes File.read(fixture.fetch(:process_log)), "yarn install --frozen-lockfile"
      refute_includes File.read(fixture.fetch(:process_log)), "rails runner -"
      assert_includes File.read(File.join(path, "log/tesseract-create.log")), "asset build failed"
      log = File.read(fixture.fetch(:herdr_log))
      assert_includes log, "pane run w7:p1"
      refute_includes log, "workspace close"
    end
  end

  def test_create_tracks_remote_branch_and_uses_configured_shared_environment
    with_runtime_fixture do |fixture|
      main = fixture.fetch(:main)
      remote = File.join(fixture.fetch(:directory), "remote.git")
      git("clone", "--bare", main, remote)
      git("--git-dir", remote, "branch", "remote-feature", "main")
      git("-C", main, "remote", "add", "origin", remote)
      shared = File.join(fixture.fetch(:directory), "shared environment")
      File.write(shared, "SHARED=yes\n")
      fixture.fetch(:environment)["TESSERACT_ENV_SHARED_PATH"] = shared
      stdout, stderr, status = run_driver(fixture, "worktree", "create", "fresh", "origin/remote-feature")
      assert status.success?, stderr
      assert_includes stdout, "branch=remote-feature"
      path = File.join(fixture.fetch(:root), "fresh")
      assert_equal shared, File.readlink(File.join(path, ".env.local"))
      assert_equal "origin/remote-feature", git("-C", path, "rev-parse", "--abbrev-ref", "@{upstream}").strip
    end
  end

  def test_create_reports_port_exhaustion_without_creating_a_worktree
    with_runtime_fixture do |fixture|
      fixture.fetch(:environment)["TESSERACT_PORT_COUNT"] = "2"
      create_executable(File.join(fixture.fetch(:directory), "fake-bin/lsof"), "exit 0")
      _stdout, stderr, status = run_driver(fixture, "worktree", "create", "fresh")
      refute status.success?
      assert_includes stderr, "no available worktree port"
      refute_path_exists File.join(fixture.fetch(:root), "fresh")
    end
  end

  def test_pending_worker_cannot_start_after_stop
    with_runtime_fixture do |fixture|
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      worker = File.read(File.join(fixture.fetch(:worktree), "log/.tesseract-active-run")).strip
      _stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")
      assert status.success?, stderr
      _stdout, _stderr, status = Open3.capture3(fixture.fetch(:environment), "bash", worker)
      refute status.success?
      assert_empty File.read(fixture.fetch(:process_log))
      refute_includes File.read(fixture.fetch(:herdr_log)), "pane run w7:p4"
    end
  end

  def test_stop_kills_preparation_children_that_ignore_term
    with_runtime_fixture(execute_setup: true, pending: true) do |fixture|
      path = fixture.fetch(:worktree)
      marker = File.join(fixture.fetch(:directory), "build.pid")
      File.write(File.join(path, "package.json"), "{}")
      create_executable(File.join(path, "bin/yarn"), "exit 0")
      create_executable(File.join(path, "bin/build"), <<~'SH')
        trap '' TERM HUP
        echo "$$" > "$BUILD_PID_FILE"
        while true; do sleep 0.05; done
      SH
      fixture.fetch(:environment)["BUILD_PID_FILE"] = marker
      _stdout, stderr, status = run_driver(fixture, "worktree", "start", "demo")
      assert status.success?, stderr
      wait_until { File.exist?(marker) }
      build_pid = Integer(File.read(marker).strip)
      _stdout, stderr, status = run_driver(fixture, "worktree", "stop", "demo")
      assert status.success?, stderr
      wait_for_worker(fixture, 143)
      wait_until do
        process_state, = Open3.capture3("ps", "-p", build_pid.to_s, "-o", "stat=")
        process_state.strip.empty? || process_state.include?("Z")
      end
      refute_includes File.read(fixture.fetch(:process_log)), "rails runner -"
      refute_includes File.read(fixture.fetch(:herdr_log)), "pane run w7:p4"
    end
  end

  private

  def with_runtime_fixture(workspace: false, tmux_running: false, execute_setup: false, pending: false)
    Dir.mktmpdir do |directory|
      main = File.join(directory, "main")
      worktree_root = File.join(directory, "worktrees")
      worktree = File.join(worktree_root, "demo")
      fake_bin = File.join(directory, "fake-bin")
      FileUtils.mkdir_p([File.join(main, "bin"), worktree_root, fake_bin])
      File.write(File.join(main, ".gitignore"), ".env*.local\n/log/*\n/.tesseract-*\n/app.crt\n/app.key\n")
      File.write(File.join(main, "tracked.txt"), "original\n")
      create_executable(File.join(main, "bin/rails"), <<~'SH')
        printf 'rails %s\n' "$*" >> "$PROCESS_LOG"
        if [ "$*" = "runner -" ]; then
          cat > "$PREPARE_SCRIPT"
          echo 'seed started'
          trap 'echo "seed cancelled" >> "$PROCESS_LOG"; exit 143' TERM HUP INT
          if [ -n "${SEED_GATE:-}" ]; then
            touch "$SEED_GATE.started"
            while [ ! -f "$SEED_GATE" ]; do sleep 0.05; done
          fi
          [ "${SEED_EXIT_STATUS:-0}" = 0 ] || exit "$SEED_EXIT_STATUS"
          echo 'seed completed'
        fi
      SH
      git("init", "-b", "main", main)
      git("-C", main, "add", ".gitignore", "bin/rails", "tracked.txt")
      git("-C", main, "-c", "user.name=Test", "-c", "user.email=test@example.test", "commit", "-m", "Fixture")
      git("-C", main, "worktree", "add", "-b", "feature/demo", worktree)
      File.write(File.join(main, ".env.local"), "SHARED=yes\n")
      %w[setup seed].each do |phase|
        File.write(File.join(worktree, ".tesseract-#{phase}.status"), "status=#{pending ? "pending" : "complete"}\n")
      end
      File.write(File.join(worktree, ".env.test.local"), "VARIABLE_NAME=sprung_dev_worktree_demo\n")
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
          DATABASE_NAME=sprung_dev_worktree_demo
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
      process_log = File.join(directory, "process.log")
      worker_log = File.join(directory, "worker.log")
      worker_result = File.join(directory, "worker.result")
      workspace_file = File.join(directory, "workspaces.json")
      File.write(workspace_file, workspace_list_json(workspace))
      FileUtils.touch([process_log, worker_log])
      create_executable(File.join(fake_bin, "dropdb"), 'printf "dropdb %s\\n" "$*" >> "$PROCESS_LOG"')
      create_executable(File.join(fake_bin, "lsof"), 'exit 1')
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
        "TESSERACT_AGENT_COMMAND" => "codex --yolo",
        "TESSERACT_AGENT_NAME" => "codex",
        "TESSERACT_HERDR_SESSION" => "default",
        "TESSERACT_CERT_PATH" => File.join(directory, "app.crt"),
        "TESSERACT_KEY_PATH" => File.join(directory, "app.key"),
        "REPOSITORY_LOG" => repository_log,
        "PROCESS_LOG" => process_log,
        "PREPARE_SCRIPT" => File.join(directory, "prepare.rb"),
        "WORKER_LOG" => worker_log,
        "WORKER_RESULT" => worker_result,
        "WORKSPACE_FILE" => workspace_file,
        "EXECUTE_SETUP" => execute_setup ? "1" : "0",
        "HERDR_LOG" => herdr_log,
        "TMUX_LOG" => tmux_log,
        "TMUX_RUNNING" => tmux_running ? "0" : "1",
        "HERDR_PANES_JSON" => panes_json(worktree)
      }

      FileUtils.touch([environment.fetch("TESSERACT_CERT_PATH"), environment.fetch("TESSERACT_KEY_PATH")])
      fixture = {
        environment: environment, directory: directory, main: main, root: worktree_root,
        worktree: worktree, repository_log: repository_log, herdr_log: herdr_log,
        tmux_log: tmux_log, process_log: process_log, worker_log: worker_log, worker_result: worker_result
      }
      begin
        yield fixture
      ensure
        if execute_setup
          submitted = File.read(herdr_log).include?("pane run w7:p3 ")
          run_driver(fixture, "worktree", "stop", "demo")
          wait_until { File.exist?(worker_result) } if submitted
        end
      end
    end
  end

  def run_driver(fixture, *arguments)
    Open3.capture3(fixture.fetch(:environment), "bash", "-s", "--", *arguments, stdin_data: File.read(DRIVER))
  end

  def git(*arguments)
    stdout, stderr, status = Open3.capture3("git", *arguments)
    assert status.success?, "git #{arguments.join(" ")}: #{stderr}"
    stdout
  end

  def wait_until
    Timeout.timeout(10) do
      sleep 0.02 until yield
    end
  end

  def wait_for_worker(fixture, expected_status)
    wait_until { File.exist?(fixture.fetch(:worker_result)) }
    assert_equal expected_status.to_s, File.read(fixture.fetch(:worker_result)).strip,
      File.read(fixture.fetch(:worker_log))
  rescue Timeout::Error
    flunk "worker timed out: #{File.read(fixture.fetch(:worker_log))}"
  end

  def create_repository_adapter(path)
    create_executable(path, <<~'SH')
      printf '%s\n' "$*" >> "$REPOSITORY_LOG"
      echo 'repo-local adapter must not be called' >&2
      exit 99
    SH
  end

  def create_fake_bundle(directory)
    create_executable(File.join(directory, "bundle"), <<~'SH')
      printf 'bundle %s\n' "$*" >> "$PROCESS_LOG"
      case "$1" in
        check) exit "${BUNDLE_CHECK_STATUS:-0}" ;;
        install) exit "${BUNDLE_INSTALL_STATUS:-0}" ;;
      esac
    SH
  end

  def create_fake_herdr(directory)
    create_executable(
      File.join(directory, "herdr"),
      <<~SH
        printf '%s\n' "$*" >> "$HERDR_LOG"
        case "$1 $2" in
          "workspace list") cat "$WORKSPACE_FILE" ;;
          "workspace create")
            printf '%s\n' '{"result":{"workspaces":[{"label":"spr/demo","workspace_id":"w7"}]}}' > "$WORKSPACE_FILE"
            printf '%s\n' '{"result":{"workspace":{"workspace_id":"w7"},"tab":{"tab_id":"w7:t1"},"root_pane":{"pane_id":"w7:p1"}}}' ;;
          "workspace close")
            printf '%s\n' '{"result":{"workspaces":[]}}' > "$WORKSPACE_FILE"
            printf '%s\n' '{"result":{"type":"workspace_closed"}}' ;;
          "workspace rename") printf '%s\n' '{"result":{"type":"workspace_renamed"}}' ;;
          "tab rename") printf '%s\n' '{"result":{"type":"tab_renamed"}}' ;;
          "tab create") printf '%s\n' '{"result":{"tab":{"tab_id":"w7:t2"},"root_pane":{"pane_id":"w7:p3"}}}' ;;
          "pane list") printf '%s\n' "$HERDR_PANES_JSON" ;;
          "pane split")
            if printf '%s\n' "$*" | grep -q 'w7:p1'; then pane=w7:p2; else
              count=$(grep -c '^pane split' "$HERDR_LOG"); count=$(( (count - 1) % 3 + 1 ))
              [ "$count" -eq 2 ] && pane=w7:p4 || pane=w7:p5
            fi
            printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
            ;;
          "pane run")
            if [ "$3" = w7:p3 ] && [ "$EXECUTE_SETUP" = 1 ]; then
              (set +e; bash -c "$4"; printf '%s\n' "$?" > "$WORKER_RESULT") > "$WORKER_LOG" 2>&1 < /dev/null &
            fi
            printf '%s\n' '{"result":{"type":"ok"}}'
            ;;
          "pane rename"|"pane report-metadata") printf '%s\n' '{"result":{"type":"ok"}}' ;;
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
