require "open3"

module Tesseract
  class LocalRunner
    class Error < StandardError; end

    def initialize(stdout:, stderr:)
      @stdout = stdout
      @stderr = stderr
    end

    def run(script)
      @stdout.print(capture(script))
      0
    end

    def capture(script)
      stdout, stderr, status = Open3.capture3({"TESSERACT_REMOTE" => "1"}, "bash", "-s", stdin_data: script)
      @stderr.print(stderr)
      raise(Error, "local command failed") unless status.success?

      stdout
    end
  end
end
