# frozen_string_literal: true

# Bearer-token gate (prEN 18239 + prEN 18216: OAuth 2.0 / OpenID Connect, JWT).
#
# Public read data is accessible without a token; write and controlled-data
# operations require an authenticated actor.
#
# Two modes, selected by DPP_AUTH_MODE:
#
#   permissive (default) — the token is decoded but not verified, and no
#     ownership is enforced. This is the scaffold behaviour: convenient for
#     development, NOT safe for production.
#   did — the token must be a self-issued JWT signed with the document key of
#     the issuer's did:oyd (see DidTokenVerifier), and every write on an
#     existing passport is checked against its recorded owner.
#
# Still open in both modes: the role model of prEN 18239 (authority,
# refurbisher, consumer) and the distinction between public data, controlled
# data and trade secrets.
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

  # The DID that presented the token, or nil.
  def actor_did
    current_actor && current_actor["iss"].presence
  end

  # Guard for every write on an existing passport. In permissive mode this is a
  # no-op — without a verified identity, ownership cannot mean anything.
  #
  # Returns true when the request may proceed; renders a Result object and
  # returns false otherwise.
  def authorize_owner!(dpp)
    return true unless DidTokenVerifier.enabled?

    owner = dpp.owner_did.to_s
    if owner.blank?
      render_result("ClientForbidden",
                    text: "This passport has no recorded owner and cannot be modified " \
                          "while DID authentication is enabled")
      return false
    end
    return true if owner == actor_did.to_s

    render_result("ClientForbidden",
                  text: "Only the economic operator that created this passport may modify it")
    false
  end

  private

  def decode_bearer_token
    header = request.authorization
    return nil unless header&.start_with?("Bearer ")

    token = header.split(" ", 2).last
    return DidTokenVerifier.call(token) if DidTokenVerifier.enabled?

    # Scaffold path: structure only, no signature. See the module comment.
    payload, = JWT.decode(token, nil, false)
    payload
  rescue JWT::DecodeError
    nil
  end
end
