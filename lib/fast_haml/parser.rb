require 'fast_haml/ast'

module FastHaml
  class Parser
    class SyntaxError < StandardError
      attr_reader :lineno

      def initialize(message, lineno)
        super("#{message} at line #{lineno}")
        @lineno = lineno
      end
    end

    def initialize(options = {})
    end

    def call(template_str)
      reset
      multiline_buf = []
      multiline_index = 0
      template_str.each_line.with_index do |line, index|
        line = line.chomp.rstrip
        if is_multiline?(line)
          line = line[0, line.size-1]
          if multiline_buf.empty?
            # multiline start
            multiline_buf << line
            multiline_index = index
          else
            # multiline continues
            multiline_buf << line.lstrip
          end
        else
          unless multiline_buf.empty?
            # multiline ended
            parse_line(multiline_buf.join, multiline_index+1)
            multiline_buf = []
          end
          parse_line(line, index+1)
        end
      end
      unless multiline_buf.empty?
        parse_line(multiline_buf.join, multiline_index+1)
      end
      if @indent_levels.last > 0
        indent_leave(0, '', -1)
      end
      @ast
    end

    private

    def reset
      @ast = Ast::Root.new
      @stack = []
      @indent_levels = [0]
    end

    MULTILINE_SUFFIX = ' |'

    # Regex to check for blocks with spaces around arguments. Not to be confused
    # with multiline script.
    # For example:
    #     foo.each do | bar |
    #       = bar
    #
    BLOCK_WITH_SPACES = /do\s*\|\s*[^\|]*\s+\|\z/o

    def is_multiline?(line)
      line.end_with?(MULTILINE_SUFFIX) && line !~ BLOCK_WITH_SPACES
    end

    DOCTYPE_PREFIX = '!'
    ELEMENT_PREFIX = '%'
    SCRIPT_PREFIX = '='
    COMMENT_PREFIX = '/'
    SILENT_SCRIPT_PREFIX = '-'
    DIV_ID_PREFIX = '#'
    DIV_CLASS_PREFIX = '.'

    def parse_line(line, lineno)
      m = line.match(/\A( *)(.*)\z/)
      indent = m[1]
      indent_level = indent.size
      text = m[2]

      if text.empty?
        return
      end

      process_indent(indent_level, text, lineno)

      case text[0]
      when ELEMENT_PREFIX
        parse_element(text, lineno)
      when DOCTYPE_PREFIX
        if text.start_with?('!!!')
          parse_doctype(text, lineno)
        else
          raise SyntaxError.new("Illegal doctype declaration", lineno)
        end
      when COMMENT_PREFIX
        parse_comment(text, lineno)
      when SCRIPT_PREFIX
        parse_script(text, lineno)
      when SILENT_SCRIPT_PREFIX
        parse_silent_script(text, lineno)
      when DIV_ID_PREFIX, DIV_CLASS_PREFIX
        parse_line("#{indent}%div#{text}", lineno)
      else
        parse_plain(text, lineno)
      end
    end

    def parse_doctype(text, lineno)
      @ast << Ast::Doctype.new(text)
    end

    def parse_comment(text, lineno)
      @ast << Ast::HtmlComment.new(text[1, text.size-1].strip)
    end

    def parse_plain(text, lineno)
      @ast << Ast::Text.new(text)
    end

    OLD_ATTRIBUTE_BEGIN = '{'
    OLD_ATTRIBUTE_END = '}'
    ELEMENT_REGEXP = /\A%([-:\w]+)([-:\w.#]*)(.+)?\z/o

    def parse_element(text, lineno)
      m = text.match(ELEMENT_REGEXP)
      unless m
        raise SyntaxError.new("Invalid element declaration", lineno)
      end

      element = Ast::Element.new
      element.tag_name = m[1]
      element.static_class, element.static_id = parse_class_and_id(m[2])
      rest = m[3]

      if rest
        rest = rest.lstrip

        new_attributes_hash = nil

        loop do
          case rest[0]
          when OLD_ATTRIBUTE_BEGIN
            unless element.old_attributes.empty?
              break
            end
            element.old_attributes, rest = parse_old_attributes(rest, lineno)
          when '('
            unless element.new_attributes.empty?
              break
            end
            element.new_attributes, rest = parse_new_attributes(rest)
          else
            break
          end
        end

        case rest[0]
        when '='
          script = rest[1 .. -1].lstrip
          if script.empty?
            raise SyntaxError.new("No Ruby code to evaluate", lineno)
          end
          element.oneline_child = Ast::Script.new([], script)
        else
          unless rest.empty?
            element.oneline_child = Ast::Text.new(rest)
          end
        end
      end

      @ast << element
    end

    OLD_ATTRIBUTE_REGEX = /[{}]/o

    def parse_old_attributes(text, lineno)
      s = StringScanner.new(text)
      s.pos = 1
      depth = 1
      while depth > 0 && s.scan_until(OLD_ATTRIBUTE_REGEX)
        if s.matched == OLD_ATTRIBUTE_BEGIN
          depth += 1
        else
          depth -= 1
        end
      end
      if depth == 0
        attr = s.pre_match + s.matched
        [attr[1, attr.size-2], s.rest.lstrip]
      else
        raise SyntaxError.new('Unmatched brace', lineno)
      end
    end

    def parse_script(text, lineno)
      script = text[/\A= *(.*)\z/, 1]
      if script.empty?
        raise SyntaxError.new("No Ruby code to evaluate", lineno)
      end
      @ast << Ast::Script.new([], script)
    end

    def parse_silent_script(text, lineno)
      script = text[/\A- *(.*)\z/, 1]
      if script.empty?
        raise SyntaxError.new("No Ruby code to evaluate", lineno)
      end
      @ast << Ast::SilentScript.new([], script)
    end

    def parse_class_and_id(class_and_id)
      classes = []
      id = ''
      class_and_id.scan(/([#.])([-:_a-zA-Z0-9]+)/) do |type, prop|
        case type
        when '.'
          classes << prop
        when '#'
          id = prop
        end
      end

      [classes.join(' '), id]
    end

    def process_indent(indent_level, text, lineno)
      if indent_level > @indent_levels.last
        indent_enter(indent_level, lineno)
      elsif indent_level < @indent_levels.last
        indent_leave(indent_level, text, lineno)
      end
    end

    def indent_enter(indent_level, lineno)
      @indent_levels.push(indent_level)
      @stack.push(@ast)
      @ast = @ast.children.last
    end

    def indent_leave(indent_level, text, lineno)
      while indent_level < @indent_levels.last
        @indent_levels.pop
        parent_ast = @stack.pop
        case @ast
        when Ast::Script, Ast::SilentScript
          @ast.mid_block_keyword = mid_block_keyword?(text)
        end
        @ast = parent_ast
      end
      if indent_level != @indent_levels.last
        raise SyntaxError.new("Unexpected indent level: #{indent_level}: indent_level=#{@indent_levels}", lineno)
      end
    end

    MID_BLOCK_KEYWORDS = %w[else elsif rescue ensure end when]
    START_BLOCK_KEYWORDS = %w[if begin case unless]
    # Try to parse assignments to block starters as best as possible
    START_BLOCK_KEYWORD_REGEX = /(?:\w+(?:,\s*\w+)*\s*=\s*)?(#{Regexp.union(START_BLOCK_KEYWORDS)})/
    BLOCK_KEYWORD_REGEX = /^-?\s*(?:(#{Regexp.union(MID_BLOCK_KEYWORDS)})|#{START_BLOCK_KEYWORD_REGEX.source})\b/

    def block_keyword(text)
      m = text.match(BLOCK_KEYWORD_REGEX)
      if m
        m[1] || m[2]
      else
        nil
      end
    end

    def mid_block_keyword?(text)
      MID_BLOCK_KEYWORDS.include?(block_keyword(text))
    end

  end
end
