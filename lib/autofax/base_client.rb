# frozen_string_literal: true

require "faraday"
require "faraday/cookie_jar"
require "faraday/follow_redirects"
require "faraday/gzip"
require "http/cookie_jar"

module Autofax
  # Base client with common HTTP functionality.
  #
  # AutoFactsDB.com is a static, catalog-only site: there is no JSON catalog
  # API, login, or per-request security token. This base client therefore just
  # owns a cookie-enabled Faraday session and URL helpers.
  class BaseClient
    BASE_URL = "https://autofactsdb.com"

    attr_reader :session, :language

    def initialize(use_mobile_profile: true, language: "en")
      # `language` is accepted for Punkauto API compatibility. AutoFactsDB is
      # English-only; the value is retained but does not alter URLs.
      @language = language.to_s.downcase
      @cookie_jar = HTTP::CookieJar.new
      @session = build_session(use_mobile_profile)
    end

    # Base URL for the vehicles catalog.
    def vehicles_base
      "#{BASE_URL}/vehicles"
    end

    # Build an absolute AutoFactsDB URL from a root-relative path.
    def localized(path)
      "#{BASE_URL}#{path}"
    end

    def close
      @session.close if @session.respond_to?(:close)
    end

    # Perform a GET request and return the raw Faraday response.
    def get(path)
      @session.get(localized(path))
    end

    private

    def build_session(use_mobile_profile)
      Faraday.new(headers: default_headers(use_mobile_profile), request: { timeout: 30, open_timeout: 30 }) do |conn|
        conn.use :cookie_jar, jar: @cookie_jar
        conn.request :url_encoded
        conn.request :gzip
        conn.response :follow_redirects
        conn.adapter Faraday.default_adapter
      end
    end

    def default_headers(use_mobile_profile)
      if use_mobile_profile
        {
          "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Mobile/15E148 Safari/604.1",
          "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language" => "en-US,en;q=0.9",
          "Accept-Encoding" => "gzip, deflate"
        }
      else
        {
          "User-Agent" => "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36",
          "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
          "Accept-Language" => "en-US,en;q=0.9",
          "Accept-Encoding" => "gzip, deflate"
        }
      end
    end
  end
end
