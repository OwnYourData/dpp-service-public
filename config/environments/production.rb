# frozen_string_literal: true

Rails.application.configure do
  config.eager_load = true
  config.consider_all_requests_local = false
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.log_tags = [:request_id]

  # Without a logger of its own Rails writes to log/production.log. In a
  # container that file is out of reach of `kubectl logs` and grows until the
  # pod restarts. The image sets RAILS_LOG_TO_STDOUT, which sends the log to
  # stdout instead.
  if ENV["RAILS_LOG_TO_STDOUT"].present?
    stdout = ActiveSupport::Logger.new($stdout)
    stdout.formatter = ::Logger::Formatter.new
    config.logger = ActiveSupport::TaggedLogging.new(stdout)
  end

  # EN 18216:2026 §6.2: all data exchange shall use TLS. Terminate TLS at the
  # proxy/load balancer and force HTTPS at the app boundary.
  #
  # Switchable, and defaulting to on, because of one case where it is wrong:
  # a stand-alone instance on somebody's own machine has no proxy in front of
  # it, so every request is redirected to https://localhost:3000, where nothing
  # is listening. The redirect is silent — the container is healthy, the log is
  # clean, and the caller sees a 301 into a void. Anything reachable from a
  # network leaves this alone.
  config.force_ssl = ENV.fetch("DPP_FORCE_SSL", "true") != "false"
  config.active_record.dump_schema_after_migration = false
end
