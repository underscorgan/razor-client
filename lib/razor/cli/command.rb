class Razor::CLI::Command
  def initialize(parse, navigate, command, segments, cmd_url)
    @dump_response = parse && parse.dump_response?
    @show_command_help = parse && parse.show_command_help?
    @navigate = navigate
    @command = command
    @cmd_schema = command['schema']
    @cmd_url = cmd_url
    @segments = segments
  end

  def run
    body = extract_command
    if @show_command_help
      @command
    else
      if body.empty?
        raise Razor::CLI::Error,
              "No arguments for command (did you forget --json ?)"
      end
      result = @navigate.json_post(@cmd_url, body)
      # Get actual object from the id.
      result = result.merge(@navigate.json_get(URI.parse(result['id']))) if result['id']
      result
    end
  end

  def extract_command
    body = {}
    until @segments.empty?
      argument = @segments.shift
      if argument =~ /\A--([a-z-]{2,})(=(.+))?\Z/ or
          argument =~ /\A-([a-z])(=(.+))?\Z/
        # `--arg=value`/`--arg value`
        # `-a=value`/`-a value`
        arg, value = [$1, $3]
        value = @segments.shift if value.nil? && @segments[0] !~ /^--/
        arg = self.class.resolve_alias(arg, @cmd_schema)
        body[arg] = self.class.convert_arg(arg, value, body[arg], @cmd_schema)
      else
        raise ArgumentError, "Unexpected argument #{argument}"
      end
    end

    begin
      body = MultiJson::load(File::read(body["json"])) if body["json"]
    rescue MultiJson::LoadError
      raise Razor::CLI::Error, "File #{body["json"]} is not valid JSON"
    rescue Errno::ENOENT
      raise Razor::CLI::Error, "File #{body["json"]} not found"
    rescue Errno::EACCES
      raise Razor::CLI::Error,
            "Permission to read file #{body["json"]} denied"
    end
    body
  end

  def self.arg_type(arg_name, cmd_schema)
    # Short-circuit to allow this as a work-around for backwards compatibility.
    return nil if arg_name == 'json'
    return nil unless cmd_schema.is_a?(Hash)
    return cmd_schema[arg_name]['type'] if cmd_schema.has_key?(arg_name)
    return nil
  end

  # `cmd_name`: The name of the command being executed.
  # `arg_name`: The name of the argument being formatted.
  # `value`: The original value provided by the user.
  # `existing_value`: The value already assigned to this variable
  #     by previous calls to this method. The new `value` will be
  #     concatenated to an array or hash if an array/hash is
  #     accepted by the command for the given argument.
  def self.convert_arg(arg_name, value, existing_value, cmd_schema)
    value = nil if value == "null"

    argument_type = arg_type(arg_name, cmd_schema)

    # This might be helpful, since there's no other method for debug-level logging on the client.
    puts "Formatting argument #{arg_name} with value #{value} as #{argument_type}\n" if @dump_response

    case argument_type
      when "array"
        existing_value ||= []
        begin
          existing_value + Array(MultiJson::load(value))
        rescue MultiJson::LoadError => _
          existing_value + Array(value)
        end
      when "object"
        existing_value ||= {}
        begin
          if value =~ /\A(.+?)=(.+)?\z/
            # `--arg name=value`
            existing_value.merge($1 => $2)
          else
            MultiJson::load(value).tap do |value|
              value.is_a?(Hash) or raise ArgumentError, "Invalid object for argument '#{arg_name}'"
              existing_value.merge(value)
            end
          end
        rescue MultiJson::LoadError => error
          raise ArgumentError, "Invalid object for argument '#{arg_name}': #{error.message}"
        end
      when "boolean"
        ["true", nil].include?(value)
      when "number"
        begin
          Integer(value)
        rescue ArgumentError
          raise ArgumentError, "Invalid integer for argument '#{arg_name}': #{value}"
        end
      when "null"
        raise ArgumentError, "Expected nothing for argument '#{arg_name}', but was: '#{value}'" unless value.nil?
        nil
      when "string", nil # `nil` for 'might be an alias, send as-is'
        value
      else
        raise Razor::CLI::Error, "Unexpected datatype '#{argument_type}' for argument #{arg_name}"
    end
  end

  def self.resolve_alias(arg_name, cmd_schema)
    return arg_name if cmd_schema[arg_name]
    cmd_schema.find do |other_attr, metadata|
      if metadata && metadata.has_key?('aliases')
        return other_attr if metadata['aliases'].find {|aliaz| aliaz == arg_name}
      end
    end
    # No results; return the same name to generate a reasonable error message.
    arg_name
  end
end