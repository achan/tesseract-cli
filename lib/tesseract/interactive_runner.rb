require "tesseract/shell"

module Tesseract
  class InteractiveRunner
    def initialize(host)
      @host = host
    end

    def attach(session)
      exec(*attach_command(session))
    end

    def attach_command(session)
      script = <<~SH
        set -eu
        exec tmux attach -t #{Shell.escape(session)}
      SH

      if @host.local?
        ["bash", "-lc", script]
      else
        ["ssh", "-t", "-o", "SendEnv=none", @host.ssh_target, "bash -lc #{Shell.escape(script)}"]
      end
    end
  end
end
