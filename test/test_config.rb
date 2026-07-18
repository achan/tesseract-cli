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

  def test_loads_case_host
    host = @config.host("case")

    assert_equal "case", host.id
    assert_equal "bot", host.user
    assert_equal "achan", host.service_user
    assert_equal "bot@case.local", host.ssh_target
    assert_equal "achan@case.local", host.service_ssh_target
    assert_equal "/Users/bot/repos", host.base_repo_path
    assert_includes host.extra_path, "/Users/bot/.homebrew/bin"
    assert_includes host.command_path, "/Users/bot/.homebrew/bin"
    refute host.local?
  end

  def test_rewrites_app_profile_for_case_host
    host = @config.host("case")
    app = @config.app("tesseract-web", host: host)

    assert_equal "/Users/bot/repos/tesseract-web", app.main_path
    assert_equal "/Users/bot/repos/tesseract-web-worktrees", app.worktree_root
    assert_equal "/Users/bot/repos/tesseract-web/.env.local", app.env_shared_path
    assert_equal "tesseract-web.case.achan.bot", app.domain
    assert_equal ["tesseract-web.case.achan.bot"], app.dns_records
  end

  def test_loads_docovia_profile
    app = @config.app("docovia")

    assert_equal "docovia", app.id
    assert_equal "git@github.com:getsprung/app", app.repo
    assert_equal "docovia.tars.achan.bot", app.domain
    assert_equal "/home/bot/repos/sprung-app", app.main_path
    assert_nil app.worktree_root
    assert_nil app.base_port
    assert_equal ["docovia.tars.achan.bot", "*.docovia.tars.achan.bot"], app.dns_records
  end

  def test_loads_flexday_profile
    app = @config.app("flexday")

    assert_equal "flexday", app.id
    assert_equal "git@github.com:FlexdayInc/flexday", app.repo
    assert_equal "flexday.tars.achan.bot", app.domain
    assert_equal "/home/bot/repos/flexday", app.main_path
    assert_equal "/home/bot/repos/flexday/.env.local", app.env_shared_path
    assert_nil app.worktree_root
    assert_nil app.base_port
    assert_empty app.runtime_specs
    assert_equal ["flexday.tars.achan.bot"], app.dns_records
  end

  def test_loads_signatures_git_worktree_profile
    app = @config.app("signatures")

    assert_equal "signatures", app.id
    assert_equal "git@github.com:achan/signatures.git", app.repo
    assert_equal "/home/bot/repos/signatures", app.main_path
    assert_equal "/home/bot/repos/signatures-worktrees", app.worktree_root
    assert_equal "git", app.worktree_driver
    assert_equal "main", app.default_branch
    assert app.fetch_on_create
    assert app.git_worktrees?
    refute app.database_enabled?
    assert_empty app.dns_records
  end

  def test_loads_chrome_extensions_git_worktree_profile
    app = @config.app("chrome-extensions")

    assert_equal "chrome-extensions", app.id
    assert_equal "git@github.com:getsprung/chrome-extensions.git", app.repo
    assert_equal "/home/bot/repos/chrome-extensions", app.main_path
    assert_equal "/home/bot/repos/chrome-extensions-worktrees", app.worktree_root
    assert_equal "git", app.worktree_driver
    assert_equal "main", app.default_branch
    assert app.git_worktrees?
    refute app.database_enabled?
    assert_empty app.dns_records
  end

  def test_loads_eso_git_worktree_profile
    app = @config.app("eso")

    assert_equal "eso", app.id
    assert_equal "git@github.com:achan/eso.git", app.repo
    assert_equal "/home/bot/repos/eso", app.main_path
    assert_equal "/home/bot/repos/eso-worktrees", app.worktree_root
    assert_equal "git", app.worktree_driver
    assert_equal "main", app.default_branch
    assert app.fetch_on_create
    assert app.git_worktrees?
    refute app.database_enabled?
    assert_empty app.dns_records
  end

  def test_rewrites_eso_profile_for_case_host
    host = @config.host("case")
    app = @config.app("eso", host: host)

    assert_equal "/Users/bot/repos/eso", app.main_path
    assert_equal "/Users/bot/repos/eso-worktrees", app.worktree_root
    assert_equal "eso.case.achan.bot", app.domain
  end

  def test_loads_tesseract_web_profile
    app = @config.app("tesseract-web")

    assert_equal "tesseract-web", app.id
    assert_equal "git@github.com:achan/tesseract.git", app.repo
    assert_equal "/home/bot/repos/tesseract-web", app.main_path
    assert_equal "/home/bot/repos/tesseract-web-worktrees", app.worktree_root
    assert_equal "tesseract-web.tars.achan.bot", app.domain
    assert_equal 6100, app.base_port
    assert_equal 99, app.port_count
    assert_equal "/home/bot/repos/tesseract-web/.env.local", app.env_shared_path
    assert_equal "repository", app.worktree_driver
    assert_equal ["tesseract-web.tars.achan.bot"], app.dns_records
  end

  def test_lists_apps
    assert_includes @config.apps.map(&:id), "chrome-extensions"
    assert_includes @config.apps.map(&:id), "docovia"
    assert_includes @config.apps.map(&:id), "eso"
    assert_includes @config.apps.map(&:id), "flexday"
    assert_includes @config.apps.map(&:id), "signatures"
    assert_includes @config.apps.map(&:id), "tesseract-web"
  end

  def test_git_worktree_profile_requires_worktree_root
    error = assert_raises(Tesseract::Config::Error) do
      Tesseract::AppProfile.new(
        "id" => "example",
        "repo" => "git@github.com:example/example.git",
        "main_path" => "/tmp/example",
        "domain" => "example.test",
        "worktree_driver" => "git"
      )
    end

    assert_equal "example git worktree profile is missing worktree_root", error.message
  end
end
