# frozen_string_literal: true

require 'apptokit/jwt'
require 'net/http'
require 'json'

require "apptokit/key_cache"

module Apptokit
  class InstallationToken
    def self.generate(installation_id: nil, skip_cache: false)
      new(installation_id: installation_id, skip_cache: skip_cache).tap(&:generate)
    end

    attr_reader :installation_id, :token, :expires_at, :skip_cache, :cached
    attr_writer :token, :expires_at, :cached
    private :token=, :expires_at=, :cached=

    def initialize(installation_id: nil, skip_cache: false)
      @skip_cache = skip_cache
      @cached = true
      @installation_id = installation_id || Apptokit.config.installation_id
    end

    def header
      generate unless token
      "token #{token}"
    end

    def generate
      if skip_cache
        self.cached = false
        perform_generation
        Apptokit.keycache.set(cache_key, token, expires_at)
        return self
      end

      token, expiry = Apptokit.keycache.get_set(cache_key, :installation, return_expiry: true) do
        self.cached = false
        perform_generation
        [self.token, expires_at]
      end

      if cached
        self.token = token
        self.expires_at = expiry.iso8601
      end

      self
    end

    def perform_generation
      uri = URI(installation_token_url)
      request = Net::HTTP::Post.new(uri)
      request["User-Agent"] = (ENV["USER_AGENT"] || "Apptokit")
      request["Accept"] = "application/vnd.github.machine-man-preview+json"
      request["Authorization"] = jwt.header

      response = Net::HTTP.start(uri.hostname, uri.port, nil, nil, nil, nil, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess then
        hash = JSON.parse(response.body)
        self.token      = hash["token"]
        self.expires_at = hash["expires_at"]
      when Net::HTTPNotFound
        $stderr.puts "The installation ID you provided is innaccessible, please verify it"
        $stderr.puts "If this App is managed via 'apptokit manifest' you can create an installation with 'apptokit manifest install'"
        exit 15
      else
        raise ApptokitError, "Could not create an Installation Token: #{response.code}\n\n#{response.body}"
      end
      self
    end

    def cache_key
      "installation:#{installation_id}"
    end

    def jwt
      @jwt ||= JWT.generate
    end

    def installation_token_url
      URI("#{Apptokit.config.github_api_url}/app/installations/#{installation_id}/access_tokens")
    end
  end
end
