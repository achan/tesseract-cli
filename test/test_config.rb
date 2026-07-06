require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "tesseract/config"

class ConfigTest < Minitest::Test
  def setup
    @config = Tesseract::Config.new(File.expand_path("..", __dir__))
  end

  def test_loads_tars_host
    host = @config.host("tars")

    assert_equal "tars", host.id
    assert_equal "bot", host.user
    assert_equal "achan", host.service_user
    assert_equal "bot@tars", host.ssh_target
    assert_equal "achan@tars", host.service_ssh_target
    assert_equal "/home/bot/repos", host.base_repo_path
    refute host.local?
  end

  def test_host_user_defaults_to_bot
    host = Tesseract::HostProfile.new(
      "id" => "example",
      "ssh_target" => "example-host",
      "base_repo_path" => "/home/bot/repos",
      "registry_dir" => "/home/bot/.local/share/tesseract/registry",
      "cert_dir" => "/home/bot/.local/share/tesseract/certs",
      "services_compose_path" => "/home/bot/.config/tesseract/services/compose.yml"
    )

    assert_equal "bot", host.user
    assert_equal "bot", host.service_user
    assert_equal "bot@example-host", host.ssh_target
    assert_equal "bot@example-host", host.service_ssh_target
  end

  def test_loads_local_host
    host = @config.host("local")

    assert_equal "local", host.id
    assert_equal "achan", host.user
    assert_equal "achan", host.service_user
    assert_equal "local", host.ssh_target
    assert_equal "local", host.service_ssh_target
    assert host.local?
  end

  def test_loads_docovia_profile
    app = @config.app("docovia")

    assert_equal "docovia", app.id
    assert_equal "git@github.com:getsprung/app", app.repo
    assert_equal "docovia.tars.achan.bot", app.domain
    assert_equal "/home/bot/repos/sprung-app", app.main_path
    assert_equal "bot", app.pguser
    assert_equal 3100, app.base_port
    assert_equal ["docovia.tars.achan.bot", "*.docovia.tars.achan.bot"], app.dns_records
  end

  def test_loads_flexday_profile
    app = @config.app("flexday")

    assert_equal "flexday", app.id
    assert_equal "git@github.com:FlexdayInc/flexday", app.repo
    assert_equal "flexday.tars.achan.bot", app.domain
    assert_equal "/home/bot/repos/flexday", app.main_path
    assert_equal "/home/bot/repos/flexday-worktrees", app.worktree_root
    assert_equal "/home/bot/repos/flexday/.env.local", app.env_shared_path
    assert_equal 4000, app.base_port
    assert_equal ["node@20.20.0"], app.runtime_specs
    assert_equal "http://{domain}:{port}", app.url_template
    assert_equal ["flexday.tars.achan.bot"], app.dns_records
    refute app.database_enabled?
  end

  def test_lists_apps
    assert_includes @config.apps.map(&:id), "docovia"
    assert_includes @config.apps.map(&:id), "flexday"
  end
end
