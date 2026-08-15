# frozen_string_literal: true

# Bearer-token gate (prEN 18239 + prEN 18216: OAuth 2.0 / OpenID Connect, JWT).
#
# SCAFFOLD: public read data is accessible without a token; write and
# controlled-data operations require an authenticated actor. The concrete
# trust framework, token scopes and role mapping (authority, refurbisher,
# consumer, ...) and — for DID FlexCo — DID-based verification, are TODO.
module TokenAuthenticatable
  extend ActiveSupport::Concern

  # Call from a before_action to require an authenticated actor.
  def authenticate_actor!
    return if current_actor.present?

    render_result("ClientNotAuthorized", text: "Missing or invalid bearer token")
  end

  # Returns the decoded token claims, or nil when unauthenticated.
  def current_actor
    return @current_actor if defined?(@current_actor)

    @current_actor = decode_bearer_token
  end

  private

  def decode_bearer_token
    header = request.authorization
    return nil unless header&.start_with?("Bearer ")

    token = header.split(" ", 2).last
    # TODO: verify signature against the OIDC provider's JWKS and validate
    # iss/aud/exp; map roles to access rights per prEN 18239 §6.2.
    payload, = JWT.decode(token, nil, false)
    payload
  rescue JWT::DecodeError
    nil
  end
end
