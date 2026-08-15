# frozen_string_literal: true

# Translates common exceptions into prEN 18222 Result objects with the correct
# generic status code / HTTP status.
module ErrorHandling
  extend ActiveSupport::Concern

  included do
    rescue_from ActiveRecord::RecordNotFound do |e|
      render_result("ClientErrorResourceNotFound", text: e.message)
    end

    rescue_from ActiveRecord::RecordNotUnique do |e|
      render_result("ClientResourceConflict", text: e.message)
    end

    rescue_from ActionController::ParameterMissing do |e|
      render_result("ClientErrorBadRequest", text: e.message)
    end

    rescue_from ActiveRecord::RecordInvalid do |e|
      render_result("ClientErrorBadRequest", text: e.record.errors.full_messages.join(", "))
    end

    rescue_from JSON::ParserError do |e|
      render_result("ClientErrorBadRequest", text: "Malformed JSON payload: #{e.message}")
    end

    # did:oyd operation failed (VDR unreachable, invalid keys, ...) — treat as
    # an upstream failure of the registry/VDR (prEN 18222 Table 16).
    rescue_from DidOyd::DidError do |e|
      render_result("ServerErrorBadGateway", text: "DID operation failed: #{e.message}")
    end

    # The hosting pod of the data intermediary is unreachable, rejected the
    # credentials, or the storage token is malformed. PodStorage carries the
    # matching generic status code (prEN 18222 Table 16).
    rescue_from PodStorage::Error do |e|
      render_result(e.status_code, text: e.message)
    end
  end
end
