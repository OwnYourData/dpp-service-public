# frozen_string_literal: true

Rails.application.configure do
  config.eager_load = true
  config.consider_all_requests_local = false
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.log_tags = [:request_id]

  # EN 18216:2026 §6.2: all data exchange shall use TLS. Terminate TLS at the
  # proxy/load balancer and force HTTPS at the app boundary.
  config.force_ssl = true
  config.active_record.dump_schema_after_migration = false
end
