module Tesseract
  module Shell
    module_function

    def escape(value)
      single_quoted(value.to_s)
    end

    def single_quoted(value)
      "'#{value.to_s.gsub("'", "'\\\\''")}'"
    end

  end
end
