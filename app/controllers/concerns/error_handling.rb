# frozen_string_literal: true

# Translates common exceptions into EN 18222:2026 Result objects with the correct
# generic status code / HTTP status.
module ErrorHandling
  extend ActiveSupport::Concern

  included do
    # Last resort, declared first so that every handler below takes precedence
    # (Rails tries them in reverse order). EN 18222:2026 Table 15 gives
    # ServerInternalError a Result object; without this the client got Rails'
    # own body instead. The cause goes to the log, not to the client.
    rescue_from StandardError do |e|
      Rails.logger.error("[error] #{e.class}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}")
      render_result("ServerInternalError", text: "Unexpected error")
    end

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
    # an upstream failure of the registry/VDR (EN 18222:2026 Table 15).
    rescue_from DidOyd::DidError do |e|
      render_result("ServerErrorBadGateway", text: "DID operation failed: #{e.message}")
    end

    # An access policy that is not valid, one a request names that is not
    # registered, or a passport that a policy cannot classify (an element
    # without an elementId). Raised before anything is written.
    rescue_from AccessPolicy::InvalidError do |e|
      render_result("ClientErrorBadRequest", text: e.message)
    end

    # A write that would hand attributes that are not public to a custodian
    # that publishes everything it holds (ControlledCards), or to a collection
    # at which the custodian has not entered this service as reader
    # (ReaderAdmission); the latter with the code "readerNotEntered".
    rescue_from Dpp::ControlledPartNotHeld do |e|
      code = e.is_a?(Dpp::ReaderNotEntered) ? Dpp::ReaderNotEntered::CODE : nil
      render_result("ClientErrorBadRequest", text: "Refused: #{e.message}", code: code)
    end

    # The same write to a custodian listed as holding controlled cards, for
    # which this deployment has no reader DID configured.
    rescue_from Dpp::ReaderNotConfigured do |e|
      Rails.logger.error("[reader] #{e.message}")
      render_result("ServerInternalError", text: "Refused: #{e.message}")
    end

    # Registered policies are immutable (RegisteredAccessPolicy).
    rescue_from RegisteredAccessPolicy::Conflict do |e|
      render_result("ClientResourceConflict", text: e.message)
    end

    # Anything that went wrong with the hosting pod already carries the generic
    # status code it should answer with: a malformed X-DPP-Storage header is a
    # client error, a refused delegation is 401 or 403 per docs/Delegation.md
    # §15, an unreachable pod is 502. Without this the same failures surfaced as
    # 500, which reads as "our bug" when it is usually a mandate problem.
    rescue_from PodStorage::Error do |e|
      render_result(e.status_code, text: e.message)
    end
  end
end
