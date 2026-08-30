require "tesseract/shell"

module Tesseract
  module WorktreeDrivers
    class Error < StandardError; end

    class Registry
      BUILTIN_DRIVERS = %w[repository git].freeze
      REQUIRED_COMMANDS = {
        "signatures" => %w[createdb git herdr jq mise ss]
      }.freeze

      def initialize(root)
        @root = root
      end

      def self.known_id?(id)
        BUILTIN_DRIVERS.include?(id) || REQUIRED_COMMANDS.key?(id)
      end

      def known?(id)
        self.class.known_id?(id) && (BUILTIN_DRIVERS.include?(id) || File.file?(driver_path(id)))
      end

      def central?(id)
        !BUILTIN_DRIVERS.include?(id) && File.file?(driver_path(id))
      end

      def fetch(id)
        raise Error, "unknown worktree driver: #{id}" unless central?(id)

        CentralScript.new(id, driver_path(id), required_commands: REQUIRED_COMMANDS.fetch(id, []))
      end

      private

      def driver_path(id)
        File.join(@root, "libexec", "tesseract", "worktree-drivers", id)
      end
    end

    class CentralScript
      attr_reader :id, :required_commands

      def initialize(id, path, required_commands: [])
        @id = id
        @source = File.read(path)
        @required_commands = required_commands
      end

      def execution_script(profile:, host:, arguments:)
        <<~SH
          #{exports(profile, host)}
          set -- #{arguments.map { |argument| Shell.escape(argument) }.join(" ")}
          #{@source}
        SH
      end

      def installation_script(directory: "$driver_dir")
        delimiter = "TESSERACT_#{id.upcase.gsub(/[^A-Z0-9]/, "_")}_DRIVER"
        <<~SH
          cat > #{directory}/#{Shell.escape(id)} <<'#{delimiter}'
          #{@source}
          #{delimiter}
          chmod 0700 #{directory}/#{Shell.escape(id)}
        SH
      end

      def remote_command(profile:, host:, executable:, arguments:)
        assignments = environment(profile, host).map do |key, value|
          "#{key}=#{Shell.escape(value)}"
        end.join(" ")
        rendered_arguments = arguments.join(" ")
        "#{assignments} #{executable} #{rendered_arguments}"
      end

      private

      def exports(profile, host)
        environment(profile, host).map do |key, value|
          "export #{key}=#{Shell.escape(value)}"
        end.join("\n")
      end

      def environment(profile, host)
        {
          "TESSERACT_APP_ID" => profile.id,
          "TESSERACT_MAIN_PATH" => profile.main_path,
          "TESSERACT_WORKTREE_ROOT" => profile.worktree_root,
          "TESSERACT_DOMAIN" => profile.domain,
          "TESSERACT_PORT_START" => profile.base_port.to_s,
          "TESSERACT_PORT_COUNT" => profile.port_count.to_s,
          "TESSERACT_DATABASE_PREFIX" => profile.database_prefix,
          "TESSERACT_CERT_PATH" => profile.cert_path(host),
          "TESSERACT_KEY_PATH" => profile.key_path(host),
          "TESSERACT_PGHOST" => "127.0.0.1",
          "TESSERACT_PGUSER" => profile.pguser,
          "TESSERACT_PGPASSWORD" => host.postgres_password,
          "TESSERACT_WEB_COMMAND" => profile.web_command,
          "TESSERACT_AGENT_COMMAND" => profile.agent_command,
          "TESSERACT_HERDR_SESSION" => "default"
        }
      end
    end
  end
end
