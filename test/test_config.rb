require "minitest/autorun"
require "fileutils"
require "tmpdir"

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
    assert_includes host.command_path, "/home/bot/.local/bin"
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

  def test_loads_sprung_profile_and_aliases
    app = @config.app("sprung")

    assert_equal "sprung", app.id
    assert_equal "sprung", app.requested_name
    assert_equal ["docovia", "smilesnap"], app.app_aliases
    assert_equal "spr", app.shorthand
    assert_equal "git@github.com:getsprung/app", app.repo
    assert_equal "docovia.tars.achan.bot", app.domain
    assert_equal "/home/bot/repos/sprung-app", app.main_path
    assert_equal "/home/bot/repos/sprung-worktrees", app.worktree_root
    assert_equal ["smilesnap.tars.achan.bot"], app.domain_aliases
    assert_equal "sprung", app.worktree_driver
    assert_equal "docovia.tars.achan.bot", app.runtime_domain
    assert_equal "Docovia", app.runtime_app_name
    assert_equal "docovia-development-public", app.public_s3_bucket
    assert_equal "docovia-public", app.cdn_bucket
    assert_equal "herdr", app.session_driver
    assert_equal 3100, app.base_port
    assert_equal [
      "docovia.tars.achan.bot",
      "*.docovia.tars.achan.bot",
      "smilesnap.tars.achan.bot",
      "*.smilesnap.tars.achan.bot"
    ], app.dns_records
    assert_equal app.dns_records, app.certificate_domains

    %w[docovia smilesnap].each do |alias_name|
      aliased = @config.app(alias_name)
      assert_equal "sprung", aliased.id
      assert_equal alias_name, aliased.requested_name
      assert_equal app.main_path, aliased.main_path
      assert_equal app.worktree_root, aliased.worktree_root
      assert_equal app.database_prefix, aliased.database_prefix
      assert_equal app.base_port, aliased.base_port
    end
    assert_equal "docovia.tars.achan.bot", @config.app("docovia").runtime_domain
    assert_equal "Docovia", @config.app("docovia").runtime_app_name
    assert_equal "docovia-development-public", @config.app("docovia").public_s3_bucket
    assert_equal "docovia-public", @config.app("docovia").cdn_bucket
    assert_equal "smilesnap.tars.achan.bot", @config.app("smilesnap").runtime_domain
    assert_equal "SmileSnap", @config.app("smilesnap").runtime_app_name
    assert_equal "smilesnap-development-public", @config.app("smilesnap").public_s3_bucket
    assert_equal "smilesnap-public", @config.app("smilesnap").cdn_bucket
  end

  def test_rewrites_sprung_primary_and_alias_domains_for_case_host
    app = @config.app("smilesnap", host: @config.host("case"))

    assert_equal "docovia.case.achan.bot", app.domain
    assert_equal ["smilesnap.case.achan.bot"], app.domain_aliases
    assert_equal "smilesnap.case.achan.bot", app.runtime_domain
    assert_equal "SmileSnap", app.runtime_app_name
    assert_equal "smilesnap-development-public", app.public_s3_bucket
    assert_equal [
      "docovia.case.achan.bot",
      "*.docovia.case.achan.bot",
      "smilesnap.case.achan.bot",
      "*.smilesnap.case.achan.bot"
    ], app.dns_records
  end

  def test_loads_flexday_profile
    app = @config.app("flexday")

    assert_equal "flexday", app.id
    assert_equal "f", app.shorthand
    assert_equal "git@github.com:FlexdayInc/flexday", app.repo
    assert_equal "flexday.tars.achan.bot", app.domain
    assert_equal "/home/bot/repos/flexday", app.main_path
    assert_equal "/home/bot/repos/flexday/.env.local", app.env_shared_path
    assert_nil app.worktree_root
    assert_nil app.base_port
    assert_empty app.runtime_specs
    assert_equal ["flexday.tars.achan.bot"], app.dns_records
  end

  def test_loads_signatures_central_worktree_profile
    app = @config.app("signatures")

    assert_equal "signatures", app.id
    assert_equal "sig", app.shorthand
    assert_equal "git@github.com:achan/signatures.git", app.repo
    assert_equal "/home/bot/repos/signatures", app.main_path
    assert_equal "/home/bot/repos/signatures-worktrees", app.worktree_root
    assert_equal "signatures", app.worktree_driver
    assert_equal "herdr", app.session_driver
    assert_equal "main", app.default_branch
    assert app.fetch_on_create
    refute app.git_worktrees?
    refute app.git_server?
    assert_equal 6200, app.base_port
    assert_equal 100, app.port_count
    assert_equal "signatures_dev_worktree", app.database_prefix
    assert_equal "bot", app.pguser
    assert_equal "bin/dev", app.web_command
    assert_equal "codex --yolo", app.agent_command
    assert_equal ["signatures.achan.bot"], app.dns_records
    assert app.database_enabled?
  end

  def test_loads_chrome_extensions_git_worktree_profile
    app = @config.app("chrome-extensions")

    assert_equal "chrome-extensions", app.id
    assert_equal "cex", app.shorthand
    assert_equal "git@github.com:getsprung/chrome-extensions.git", app.repo
    assert_equal "/home/bot/repos/chrome-extensions", app.main_path
    assert_equal "/home/bot/repos/chrome-extensions-worktrees", app.worktree_root
    assert_equal "git", app.worktree_driver
    assert_equal "main", app.default_branch
    assert app.git_worktrees?
    refute app.database_enabled?
    assert_empty app.dns_records
  end

  def test_loads_mobile_dashboard_repository_worktree_profile
    app = @config.app("mobile-dashboard")

    assert_equal "mobile-dashboard", app.id
    assert_equal "md", app.shorthand
    assert_equal "git@github.com:getsprung/mobile-dashboard.git", app.repo
    assert_equal "/home/bot/repos/mobile-dashboard", app.main_path
    assert_equal "/home/bot/repos/mobile-dashboard-worktrees", app.worktree_root
    assert_equal "repository", app.worktree_driver
    assert_equal "main", app.default_branch
    assert app.fetch_on_create
    refute app.git_worktrees?
    refute app.database_enabled?
    assert_empty app.dns_records
  end

  def test_rewrites_mobile_dashboard_profile_for_case_host
    host = @config.host("case")
    app = @config.app("mobile-dashboard", host: host)

    assert_equal "/Users/bot/repos/mobile-dashboard", app.main_path
    assert_equal "/Users/bot/repos/mobile-dashboard-worktrees", app.worktree_root
    assert_equal "mobile-dashboard.case.achan.bot", app.domain
  end

  def test_defines_worktree_display_shorthands_for_current_and_future_apps
    assert_equal(
      {
        "signatures" => "sig",
        "sprung" => "spr",
        "docovia" => "doc",
        "smilesnap" => "ss",
        "flexday" => "f",
        "chrome-extensions" => "cex",
        "tesseract-web" => "tess",
        "mobile-dashboard" => "md"
      },
      %w[
        signatures sprung docovia smilesnap flexday chrome-extensions
        tesseract-web mobile-dashboard
      ].to_h { |id| [id, @config.app_shorthand(id)] }
    )
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
    assert_includes @config.apps.map(&:id), "sprung"
    refute_includes @config.apps.map(&:id), "docovia"
    refute_includes @config.apps.map(&:id), "smilesnap"
    assert_includes @config.apps.map(&:id), "eso"
    assert_includes @config.apps.map(&:id), "flexday"
    assert_includes @config.apps.map(&:id), "mobile-dashboard"
    assert_includes @config.apps.map(&:id), "signatures"
    assert_includes @config.apps.map(&:id), "tesseract-web"
  end

  def test_rejects_app_alias_collisions
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config", "apps"))
      File.write(File.join(root, "config", "app-shorthands.yml"), "{}\n")
      base = {
        "repo" => "example/repo",
        "main_path" => "/tmp/example",
        "domain" => "example.test"
      }
      File.write(
        File.join(root, "config", "apps", "one.yml"),
        YAML.dump(base.merge("id" => "one", "app_aliases" => ["shared"]))
      )
      File.write(
        File.join(root, "config", "apps", "two.yml"),
        YAML.dump(base.merge("id" => "two", "app_aliases" => ["shared"]))
      )

      error = assert_raises(Tesseract::Config::Error) { Tesseract::Config.new(root).apps }
      assert_equal "app name or alias shared is used by both one and two", error.message
    end
  end

  def test_lists_configured_hosts
    assert_equal ["case", "local", "tars"], @config.hosts.map(&:id)
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

  def test_app_profile_rejects_unknown_session_driver
    error = assert_raises(Tesseract::Config::Error) do
      Tesseract::AppProfile.new(
        "id" => "example",
        "repo" => "git@github.com:example/example.git",
        "main_path" => "/tmp/example",
        "domain" => "example.test",
        "session_driver" => "screen"
      )
    end

    assert_equal "example profile has invalid session_driver: screen", error.message
  end
end
