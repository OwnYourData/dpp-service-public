# frozen_string_literal: true

require_relative "boot"

require "rails"
# Pick only the frameworks needed for an API-only service.
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module DppService
  class Application < Rails::Application
    config.load_defaults 7.1

    # API-only: no views, cookies or sessions middleware.
    config.api_only = true

    # Autoload app/lib (RFC 7396 merge patch, etc.).
    config.autoload_paths << Rails.root.join("app", "lib")

    # All identifiers/paths are UTF-8; timestamps are UTC (EN 18223:2026 LastUpdate).
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc
  end
end
