# frozen_string_literal: true

# Maps the technology-neutral generic status codes of EN 18222:2026 (Table 15)
# to HTTP status codes, and renders the Result/Message object (Tables 12–14).
module ApiStatus
  extend ActiveSupport::Concern

  # Generic status code (EN 18222:2026 Table 15) => HTTP status.
  STATUS_MAP = {
    "Success"                     => :ok,                    # 200
    "SuccessCreated"              => :created,               # 201
    "SuccessAccepted"             => :accepted,              # 202
    "SuccessNoContent"            => :no_content,            # 204
    "ClientErrorBadRequest"       => :bad_request,           # 400
    "ClientNotAuthorized"         => :unauthorized,          # 401
    "ClientForbidden"             => :forbidden,             # 403
    "ClientMethodNotAllowed"      => :method_not_allowed,    # 405
    "ClientErrorResourceNotFound" => :not_found,             # 404
    "ClientResourceConflict"      => :conflict,              # 409
    "ServerInternalError"         => :internal_server_error, # 500
    "ServerErrorBadGateway"       => :bad_gateway            # 502
  }.freeze

  MESSAGE_TYPES = %w[Info Warning Error Exception].freeze

  # Render a successful payload with the mapped HTTP status.
  #
  # Serialized here rather than by +render json:+, which passes a String through
  # as if it were JSON already. A single data element in the compressed form can
  # be a bare string (EN 18223:2026 5.2.6), and it has to arrive quoted.
  def render_dpp(payload, status_code: "Success")
    http = STATUS_MAP.fetch(status_code, :ok)
    if http == :no_content
      head :no_content
    else
      render json: payload.to_json, status: http
    end
  end

  # Build a Result object (EN 18222:2026 Table 12) and render it.
  def render_result(status_code, text:, message_type: "Error", code: nil)
    result = {
      statusCode: status_code,
      message: [
        {
          messageType: message_type,
          text: text,
          code: code,
          correlationId: request.request_id,
          timestamp: Time.now.utc.iso8601
        }.compact
      ]
    }
    render json: result, status: STATUS_MAP.fetch(status_code, :internal_server_error)
  end
end
