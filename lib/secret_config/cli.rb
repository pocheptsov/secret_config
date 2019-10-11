require "optparse"
require "fileutils"
require "erb"
require "yaml"
require "json"
require "securerandom"
require "irb"

module SecretConfig
  class CLI
    attr_reader :path, :region, :provider,
                :export, :no_filter,
                :import, :key_id, :key_alias, :random_size, :prune, :overwrite,
                :fetch_key, :delete_key, :set_key, :set_value, :delete_path,
                :copy_path, :diff,
                :console,
                :show_version

    PROVIDERS = %i[ssm].freeze

    def self.run!(argv)
      new(argv).run!
    end

    def initialize(argv)
      @export       = false
      @import       = false
      @path         = nil
      @key_id       = nil
      @key_alias    = nil
      @region       = ENV["AWS_REGION"]
      @provider     = :ssm
      @random_size  = 32
      @no_filter    = false
      @prune        = false
      @replace      = false
      @copy_path    = nil
      @show_version = false
      @console      = false
      @diff         = false
      @set_key      = nil
      @set_value    = nil
      @fetch_key    = nil
      @delete_key   = nil
      @delete_path  = nil

      if argv.empty?
        puts parser
        exit(-10)
      end
      parser.parse!(argv)
    end

    def run!
      if show_version
        puts "Secret Config v#{VERSION}"
        puts "Region: #{region}"
      elsif console
        run_console
      elsif export
        run_export(export, filtered: !no_filter)
      elsif import && prune
        run_import_and_prune(import)
      elsif import
        run_import(import)
      elsif copy_path
        run_copy(copy_path, path)
      elsif diff
        run_diff(diff)
      elsif set_key
        run_set(set_key, set_value)
      elsif fetch_key
        run_fetch(fetch_key)
      elsif delete_key
        run_delete(delete_key)
      elsif delete_path
        run_delete_path(delete_path)
      else
        puts parser
      end
    end

    def parser
      @parser ||= OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Secret Config v#{VERSION}

            For more information, see: https://rocketjob.github.io/secret_config/

          secret_config [options]
        BANNER

        opts.on "-e", "--export [FILE_NAME]", "Export configuration to a file or stdout if no file_name supplied." do |file_name|
          @export = file_name || STDOUT
        end

        opts.on "-i", "--import [FILE_NAME]", "Import configuration from a file or stdin if no file_name supplied." do |file_name|
          @import = file_name || STDIN
        end

        opts.on "--copy SOURCE_PATH", "Import configuration from a file or stdin if no file_name supplied." do |path|
          @copy_path = path
        end

        opts.on "--diff [FILE_NAME]", "Compare configuration from a file or stdin if no file_name supplied." do |file_name|
          @diff = file_name
        end

        opts.on "-s", "--set KEY=VALUE", "Set one key to value. Example: --set mysql/database=localhost" do |param|
          @set_key, @set_value = param.split("=")
          unless @set_key && @set_value
            raise(ArgumentError, "Supply key and value separated by '='. Example: --set mysql/database=localhost")
          end
        end

        opts.on "-f", "--fetch KEY", "Fetch the value for one setting. Example: --get mysql/database. " do |key|
          @fetch_key = key
        end

        opts.on "-d", "--delete KEY", "Delete one specific key. See --delete-path to delete all keys under a specific path " do |key|
          @delete_key = key
        end

        opts.on "-r", "--delete-path PATH", "Recursively delete all keys under the specified path.. " do |path|
          @delete_path = path
        end

        opts.on "-c", "--console", "Start interactive console." do
          @console = true
        end

        opts.on "-p", "--path PATH", "Path to import from / export to." do |path|
          @path = path
        end

        opts.on "--provider PROVIDER", "Provider to use. [ssm | file]. Default: ssm" do |provider|
          @provider = provider.to_sym
        end

        opts.on "--no-filter", "Do not filter passwords and keys." do
          @no_filter = true
        end

        opts.on "--prune", "During import delete all existing keys for which there is no key in the import file." do
          @prune = true
        end

        opts.on "--key_id KEY_ID", "Encrypt config settings with this AWS KMS key id. Default: AWS Default key." do |key_id|
          @key_id = key_id
        end

        opts.on "--key_alias KEY_ALIAS", "Encrypt config settings with this AWS KMS alias." do |key_alias|
          @key_alias = key_alias
        end

        opts.on "--region REGION", "AWS Region to use. Default: AWS_REGION env var." do |region|
          @region = region
        end

        opts.on "--random_size INTEGER", Integer, "Size to use when generating random values. Whenever #{RANDOM} is encountered during an import. Default: 32" do |random_size|
          @random_size = random_size
        end

        opts.on "-v", "--version", "Display Symmetric Encryption version." do
          @show_version = true
        end

        opts.on("-h", "--help", "Prints this help.") do
          puts opts
          exit
        end
      end
    end

    private

    def provider_instance
      @provider_instance ||= begin
        case provider
        when :ssm
          Providers::Ssm.new(key_id: key_id, key_alias: key_alias)
        else
          raise ArgumentError, "Invalid provider: #{provider}"
        end
      end
    end

    def run_export(file_name, filtered: true)
      config = fetch_config(path, filtered: filtered)
      write_config_file(file_name, config)

      puts("Exported #{path} from #{provider} to #{file_name}") if file_name.is_a?(String)
    end

    def run_import(file_name)
      config = read_config_file(file_name)

      set_config(config, path, current_values)

      puts("Imported #{file_name} to #{provider} at #{path}") if file_name.is_a?(String)
    end

    def run_import_and_prune(file_name)
      config      = read_config_file(file_name)
      delete_keys = current_values.keys - Utils.flatten(config, path).keys

      unless delete_keys.empty?
        puts "Going to delete the following keys:"
        delete_keys.each { |key| puts "  #{key}" }
        sleep(5)
      end

      set_config(config, path, current_values)

      delete_keys.each do |key|
        puts "Deleting: #{key}"
        provider_instance.delete(key)
      end

      puts("Imported #{file_name} to #{provider} at #{path}") if file_name.is_a?(String)
    end

    def run_copy(source_path, target_path)
      config = fetch_config(source_path, filtered: false)

      set_config(config, target_path, current_values)

      puts "Copied #{source_path} to #{target_path} using #{provider}"
    end

    def run_diff(file_name)
      file_config = read_config_file(file_name)
      file        = Utils.flatten(file_config, path)

      registry_config = fetch_config(path, filtered: false)
      registry        = Utils.flatten(registry_config, path)

      (file.keys + registry.keys).sort.uniq.each do |key|
        if registry.key?(key)
          if file.key?(key)
            value = file[key].to_s
            # Ignore filtered values
            puts "* #{key}: #{registry[key]} => #{file[key]}" if (value != registry[key].to_s) && (value != FILTERED)
          else
            puts "- #{key}"
          end
        elsif file.key?(key)
          puts "+ #{key}: #{file[key]}"
        end
      end

      puts("Compared #{file_name} to #{provider} at #{path}") if file_name.is_a?(String)
    end

    def run_console
      IRB.start
    end

    def run_delete(key)
      provider_instance.delete(key)
    end

    def run_fetch(key)
      value = provider_instance.fetch(key)
      puts value if value
    end

    def run_set(key, value)
      provider_instance.set(key, value)
    end

    def current_values
      @current_values ||= Utils.flatten(fetch_config(path, filtered: false), path)
    end

    def read_config_file(file_name)
      format = file_format(file_name)
      data   = read_file(file_name)
      parse(data, format)
    end

    def write_config_file(file_name, config)
      format = file_format(file_name)
      data   = render(config, format)
      write_file(file_name, data)
    end

    def set_config(config, path, current_values = {})
      Utils.flatten_each(config, path) do |key, value|
        next if value.nil?
        next if current_values[key].to_s == value.to_s

        if value.to_s.strip == RANDOM
          next if current_values[key]

          value = random_password
        elsif value == FILTERED
          # Ignore filtered values
          next
        end
        puts "Setting: #{key}"
        provider_instance.set(key, value)
      end
    end

    def fetch_config(path, filtered: true)
      registry = Registry.new(path: path, provider: provider_instance)
      config   = filtered ? registry.configuration : registry.configuration(filters: nil)
      sort_hash_by_key!(config)
    end

    def read_file(file_name_or_io)
      return file_name_or_io.read unless file_name_or_io.is_a?(String)

      ::File.new(file_name_or_io).read
    end

    def write_file(file_name_or_io, data)
      return file_name_or_io.write(data) unless file_name_or_io.is_a?(String)

      output_path = ::File.dirname(file_name_or_io)
      FileUtils.mkdir_p(output_path) unless ::File.exist?(output_path)

      ::File.open(file_name_or_io, "w") { |io| io.write(data) }
    end

    def render(hash, format)
      case format
      when :yml
        hash.to_yaml
      when :json
        hash.to_json
      else
        raise ArgumentError, "Invalid format: #{format.inspect}"
      end
    end

    def parse(data, format)
      config =
        case format
        when :yml
          YAML.safe_load(ERB.new(data).result)
        when :json
          JSON.parse(data)
        else
          raise ArgumentError, "Invalid format: #{format.inspect}"
        end
      sort_hash_by_key!(config)
    end

    def file_format(file_name)
      return :yml unless file_name.is_a?(String)

      case File.extname(file_name).downcase
      when ".yml", ".yaml"
        :yml
      when ".json"
        :json
      else
        raise ArgumentError, "Import/Export file name must end with '.yml' or '.json'"
      end
    end

    def random_password
      SecureRandom.urlsafe_base64(random_size)
    end

    def sort_hash_by_key!(h)
      h.keys.sort.each do |key|
        value = h[key] = h.delete(key)
        sort_hash_by_key!(value) if value.is_a?(Hash)
      end
      h
    end
  end
end
