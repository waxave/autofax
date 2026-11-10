# frozen_string_literal: true

module Autofax
  # Base error for all Autofax errors.
  class Error < StandardError; end

  # Raised when an HTTP or API-level request fails.
  class ApiError < Error; end

  # Raised when a feature requires an authenticated session but none exists.
  class AuthenticationRequiredError < Error; end

  # Raised when the target site's anti-bot system demands a CAPTCHA.
  class CaptchaError < Error; end

  # Raised when the order status lookup cannot locate an order.
  class OrderNotFoundError < Error; end

  # Raised when a RockAuto API feature has no equivalent on AutoFactsDB.com.
  #
  # AutoFactsDB is a catalog-only site (no orders, accounts, login, or tools
  # section). The public client keeps the full Punkauto-compatible surface,
  # but methods that depend on RockAuto-only features raise this error.
  class NotSupportedError < Error; end
end
