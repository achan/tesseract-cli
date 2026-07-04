require "yaml"

module Tesseract
  class Config
    class Error < StandardError; end

    def self.default_root
      File.expand_path("../..", __dir__)
    end

    def initialize(root)
      @root = root
    end

    def host(id)
      path = File.join(@root, "config", "hosts", "#{id}.yml")
      raise Error, "unknown host: #{id}" unless File.file?(path)

      HostProfile.new(load_yaml(path))
    end

    def app(id)
      path = File.join(@root, "config", "apps", "#{id}.yml")
      raise Error, "unknown app: #{id}" unless File.file?(path)

      AppProfile.new(load_yaml(path))
    end

    def apps
      Dir.glob(File.join(@root, "config", "apps", "*.yml")).sort.map do |path|
        AppProfile.new(load_yaml(path))
      end
    end

    private

    def load_yaml(path)
      YAML.safe_load_file(path, aliases: true)
    rescue Psych::Exception => error
      raise Error, "invalid YAML in #{path}: #{error.message}"
    end
  end

  class HostProfile
    DEFAULT_USER = "bot"

    attr_reader :id, :user, :service_user, :host_name, :base_repo_path,
      :registry_dir, :cert_dir, :services_compose_path

    def initialize(data)
      @id = required(data, "id")
      @user = data.fetch("user", DEFAULT_USER)
      @service_user = data.fetch("service_user", @user)
      @host_name = required(data, "ssh_target")
      @base_repo_path = required(data, "base_repo_path")
      @registry_dir = required(data, "registry_dir")
      @cert_dir = required(data, "cert_dir")
      @services_compose_path = required(data, "services_compose_path")
      @local = data.fetch("local", false)
      @services = data.fetch("services", {})
    end

    def local?
      @local
    end

    def ssh_target
      return @host_name if local? || @host_name.include?("@")

      "#{@user}@#{@host_name}"
    end

    def service_ssh_target
      return @host_name if local? || @host_name.include?("@")

      "#{@service_user}@#{@host_name}"
    end

    def services_compose
      postgres = @services.fetch("postgres", {})
      redis = @services.fetch("redis", {})

      <<~YAML
        services:
          postgres:
            image: #{postgres.fetch("image", "pgvector/pgvector:pg14")}
            container_name: tesseract-postgres
            environment:
              POSTGRES_USER: #{postgres.fetch("user", @user)}
              POSTGRES_PASSWORD: #{postgres.fetch("password", "dev")}
              POSTGRES_DB: postgres
            ports:
              - "127.0.0.1:#{postgres.fetch("port", 5432)}:5432"
            volumes:
              - postgres-data:/var/lib/postgresql/data
          redis:
            image: #{redis.fetch("image", "redis:7-alpine")}
            container_name: tesseract-redis
            command: ["redis-server", "--databases", "#{redis.fetch("databases", 256)}"]
            ports:
              - "127.0.0.1:#{redis.fetch("port", 6379)}:6379"
            volumes:
              - redis-data:/data
        volumes:
          postgres-data:
          redis-data:
      YAML
    end

    def postgres_password
      @services.fetch("postgres", {}).fetch("password", "dev")
    end

    private

    def required(data, key)
      data.fetch(key) { raise Config::Error, "host profile is missing #{key}" }
    end
  end

  class AppProfile
    attr_reader :id, :repo, :main_path, :worktree_root, :domain, :base_port,
      :port_count, :database_prefix, :env_shared_path, :pguser

    def initialize(data)
      @id = required(data, "id")
      @repo = required(data, "repo")
      @main_path = required(data, "main_path")
      @worktree_root = required(data, "worktree_root")
      @domain = required(data, "domain")
      @base_port = Integer(required(data, "base_port"))
      @port_count = Integer(data.fetch("port_count", 99))
      @database_prefix = required(data, "database_prefix")
      @env_shared_path = required(data, "env_shared_path")
      @pguser = data.fetch("pguser", "achan")
      @processes = data.fetch("processes", {})
    end

    def cert_path(host)
      File.join(host.cert_dir, "#{domain}.crt")
    end

    def key_path(host)
      File.join(host.cert_dir, "#{domain}.key")
    end

    def web_command
      required_process("web")
    end

    def worker_command
      required_process("worker")
    end

    def asset_command
      @processes["assets"].to_s
    end

    def agent_command
      @processes.fetch("agent", "claude")
    end

    private

    def required(data, key)
      data.fetch(key) { raise Config::Error, "app profile is missing #{key}" }
    end

    def required_process(name)
      @processes.fetch(name) { raise Config::Error, "#{id} profile is missing process #{name}" }
    end
  end
end
