require "tesseract/shell"
require "open3"

module Tesseract
  class InteractiveRunner
    class Error < StandardError; end

    def initialize(host)
      @host = host
    end

    def attach(session)
      exec(*attach_command(session))
    end

    def attach_command(session)
      script = <<~SH
        set -eu
        export PATH=#{Shell.escape(@host.command_path)}
        exec tmux attach -t #{Shell.escape(session)}
      SH

      if @host.local?
        ["bash", "-lc", script]
      else
        ["ssh", "-t", "-o", "SendEnv=none", @host.ssh_target, "bash -lc #{Shell.escape(script)}"]
      end
    end

    def attach_worktree(profile, slug)
      status = worktree_status(profile, slug)
      raise Error, "#{profile.id}/#{slug} is not running" unless status["running"] == "yes"

      runtime = status["runtime"]
      runtime = "tmux" if runtime.to_s.empty? && status["tmux_session"]
      runtime = profile.session_driver if runtime.to_s.empty?

      case runtime
      when "tmux"
        session = status["tmux_session"] || status["session"]
        raise Error, "#{profile.id}/#{slug} did not report a tmux session" if session.to_s.empty?

        attach(session)
      when "herdr"
        workspace_id = status["workspace_id"]
        session = status.fetch("session", "default")
        raise Error, "#{profile.id}/#{slug} did not report a Herdr workspace" if workspace_id.to_s.empty?

        focus_herdr_workspace(workspace_id, session)
        exec(*herdr_attach_command(session))
      else
        raise Error, "#{profile.id}/#{slug} reported unknown runtime: #{runtime}"
      end
    end

    def herdr_attach_command(session = "default")
      command = ["herdr"]
      if @host.local?
        command.concat(["--session", session]) unless session == "default"
      else
        command.concat(["--remote", @host.ssh_target])
        command.concat(["--session", session]) unless session == "default"
      end
      command
    end

    private

    def worktree_status(profile, slug)
      script = <<~SH
        set -eu
        export PATH=#{Shell.escape(@host.command_path)}
        cd #{Shell.escape(profile.main_path)}
        exec ./bin/tesseract worktree status #{Shell.escape(slug)}
      SH
      output = capture(script)
      output.lines.filter_map do |line|
        key, value = line.chomp.split("=", 2)
        [key, value] if value
      end.to_h
    end

    def focus_herdr_workspace(workspace_id, session)
      script = <<~SH
        set -eu
        export PATH=#{Shell.escape(@host.command_path)}
        HERDR_SESSION=#{Shell.escape(session)} herdr workspace focus #{Shell.escape(workspace_id)} >/dev/null
      SH
      capture(script)
    end

    def capture(script)
      command = if @host.local?
        ["bash", "-lc", script]
      else
        ["ssh", "-o", "SendEnv=none", @host.ssh_target, "bash -lc #{Shell.escape(script)}"]
      end
      stdout, stderr, status = Open3.capture3(*command)
      raise Error, stderr.strip.empty? ? "interactive preflight failed" : stderr.strip unless status.success?

      stdout
    end
  end
end
