# frozen_string_literal: true

require 'pathname'
require 'openssl'
require 'yaml'
require 'uri'

module Apptokit
  class ConfigLoader
    HOME_DIR_CONF_PATH = Pathname.new(ENV["HOME"]).join(".config/apptokit.yml")
    HOME_DIR_CONF_DIR = Pathname.new(ENV["HOME"]).join(".config/apptokit")
    PROJECT_DIR_CONF_PATH = Pathname.new(Dir.pwd).join(".apptokit.yml")

    def self.environments
      envs = []
      [HOME_DIR_CONF_PATH, PROJECT_DIR_CONF_PATH].each do |path|
        envs += (YAML.load_file(path).keys - Apptokit::Configuration::YAML_OPTS) if path.exist?
      end
      (envs - %w(default_env)).reject { |e| /_defaults/.match?(e) }
    end

    def self.loading_manifest(&block)
      if block
        @loading_manifest = true
        block.call
        @loading_manifest = false
      else
        @loading_manifest ||= nil
      end
    end

    def self.load!
      new.tap(&:load!)
    end

    def self.to_shell
      new.tap(&:load_from_config!).to_shell
    end

    attr_reader :config, :manifest_data, :default_env
    private :config

    def initialize
      @config = {}
    end

    def load!
      if ENV.key?("APPTOKIT_LOADED_ENV") && read_from_env("loaded_env") == env
        read_from_env!
      else
        load_from_config!
      end
    end

    def reload!
      @config = {}
      @manifest_data = nil
      @env = nil
      @default_env = nil
      load!
    end

    def read_from_env!
      set_opts_from_env
    end

    def load_from_config!
      set_opts_from_yaml(HOME_DIR_CONF_PATH)
      set_opts_from_yaml(PROJECT_DIR_CONF_PATH)
      set_opts_from_cached_manifest
      set_opts_from_env
    end

    def fetch(var, default = nil, &block)
      # puts "fetching #{var}"
      if respond_to?(var.intern)
        send(var.intern)
      else
        config.fetch(var, default, &block)
      end
    end

    def private_key_path
      config['private_key_path'] ||= Dir[private_key_path_glob].max
    end

    def private_key_path_glob
      config['private_key_path_glob'] ||= Pathname.new(Dir.pwd).join("*.pem")
    end

    def env
      @env ||= ENV["APPTOKIT_ENV"] || ENV["GH_ENV"] || read_from_env("default_env") || @default_env
    end

    def env_from_manifest?
      config['manifest_url'].present? || !manifest_data.nil?
    end

    def clear_manifest_cache!
      ManifestApp.delete_cache(self)
    end

    def debug(msg = nil, &block)
      return unless debug?
      return block.call if block

      $stderr.puts msg
    end

    def to_shell
      values = Configuration::DUMPABLE_OPTIONS.map do |opt|
        value = fetch(opt)
        next unless value

        "APPTOKIT_#{opt.upcase}=#{value}"
      end.compact
      values << "APPTOKIT_LOADED_ENV=#{env}"
      values << "APPTOKIT_DEFAULT_ENV=#{@default_env}" if @default_env
      values.join("\n")
    end

    private

    def set_opts_from_hash(hash)
      Apptokit::Configuration::YAML_OPTS.each do |opt|
        if (value = hash[opt])
          if respond_to?(:"#{opt}=")
            send(:"#{opt}=", value)
          else
            config[opt] = value
          end
        end
      end
    end

    def set_opts_from_yaml(path)
      return unless path.exist?

      yaml = if RUBY_VERSION < '2.5'
        YAML.load(path.read) # rubocop:disable Security/YAMLLoad
      else
        YAML.safe_load(path.read, aliases: true)
      end
      set_opts_from_hash(yaml)

      @default_env = yaml["default_env"] if yaml["default_env"]
      @env = yaml["default_env"] unless env

      return unless env

      env_overrides = yaml[env]
      debug { $stderr.puts "loading #{env} from #{path} #{env_overrides.inspect}" }
      set_opts_from_hash(env_overrides) if env_overrides
    end

    def set_opts_from_cached_manifest
      debug { $stderr.puts "loading manifest if available for #{env} #{@config}" }
      manifest_settings, raw_config = ManifestApp.load_from_cache(self)

      return if raw_config == :unavailable

      debug { $stderr.puts "loading cached manifest #{manifest_settings} #{raw_config}" }
      @config = @config.merge(manifest_settings)
      @manifest_data = raw_config
    end

    def set_opts_from_env
      set_opts_from_hash(Apptokit::Configuration::YAML_OPTS.each_with_object({}) do |opt, out|
        value = read_from_env(opt)
        next unless value

        out[opt] = value
      end)
    end

    def realize_manifest?
      !ENV.key?("LIMITED_MANIFEST")
    end

    def read_from_env(name)
      value = ENV["APPTOKIT_#{name.upcase}"]
      return unless value

      value
    end

    def debug?
      ENV.key?("DEBUG")
    end
  end
end
