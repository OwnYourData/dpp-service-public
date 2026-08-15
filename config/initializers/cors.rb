# frozen_string_literal: true

# Controlled cross-origin access so browser-based DPP viewers can read public
# data (prEN 18239 §6.2 — unauthenticated read of public DPP data).
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("DPP_CORS_ORIGINS", "*")
    resource "*",
             headers: :any,
             methods: %i[get post patch delete options head],
             expose: %w[Link X-Next-Cursor]
  end
end
