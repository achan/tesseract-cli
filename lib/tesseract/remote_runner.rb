require "open3"

module Tesseract
  class RemoteRunner
    class Error < StandardError; end

    def initialize(host, stdout:, stderr:, ssh_target: nil)
      @host = host
      @ssh_target = ssh_target || host.ssh_target
      @stdout = stdout
      @stderr = stderr
    end

    def run(script)
      stdout, stderr, status = Open3.capture3(
        {
          "TESSERACT_REMOTE" => "1",
          "LANG" => "C.UTF-8",
          "LC_ALL" => "C.UTF-8"
        },
        "ssh",
        "-o",
        "SendEnv=none",
        @ssh_target,
        "env",
        "PATH=#{@host.command_path}",
        "bash",
        "-s",
        stdin_data: script
      )
      @stdout.print(stdout)
      @stderr.print(stderr)
      raise Error, "remote command failed on #{@ssh_target}" unless status.success?

      0
    end
  end
end
