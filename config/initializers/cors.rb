# frozen_string_literal: true

# Cross-origin access for browser clients.
#
# Reading is public (EN 18239 6.2: public DPP data is readable without
# authentication), so any origin may read: GET and HEAD everywhere, and the one
# read that is a POST, ReadDPPIdsByProductIds.
#
# Writing from a browser is allowed only for the origins listed in
# DPP_CORS_ORIGINS (comma-separated). The default is none: the DPP Manager and
# other operator tools call this service from a server, where CORS does not
# apply, and a write interface open to every web page is an invitation nobody
# needs.
write_origins = ENV.fetch("DPP_CORS_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
exposed = %w[Link X-Next-Cursor X-DPP-Payload-Hash X-DPP-Commit-State X-DPP-Retain-Until Retry-After]

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  if write_origins.any?
    allow do
      origins(*write_origins)
      resource "*", headers: :any, methods: %i[get post patch delete options head], expose: exposed
    end
  end

  allow do
    origins "*"
    resource "/dpp/v1/dppsByProductIds", headers: :any, methods: %i[post options], expose: exposed
    resource "*", headers: :any, methods: %i[get head options], expose: exposed
  end
end
