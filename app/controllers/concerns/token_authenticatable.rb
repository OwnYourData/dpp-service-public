# frozen_string_literal: true

# Bearer-token gate (EN 18239:2026 + EN 18216:2026: OAuth 2.0 / OpenID Connect, JWT).
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
# Who may read the controlled part of a passport beyond its owner is decided by
# access grants (AccessGrant), on the read paths (ReaderAccess, PassportAccess).
module TokenAuthenticatable
  extend ActiveSupport::Concern

  def process_action(*)
    super
  ensure
    record_write_outcome
  end

  # The operations that change something, by controller and action, as the
  # write log names them (EN 18222:2026 names where the standard has one).
  WRITE_OPERATIONS = {
    "api/v1/dpps#create" => "CreateDPP",
    "api/v1/dpps#update" => "UpdateDPPById",
    "api/v1/dpps#destroy" => "DeleteDPPById",
    "api/v1/dpps#move_custody" => "changeCustodian",
    "api/v1/dpps#renew_delegation" => "renewDelegation",
    "api/v1/data_elements#update" => "UpdateDataElement",
    "api/v1/data_element_collections#update" => "UpdateDataElementCollection",
    "api/v1/registry#create" => "RegisterProductDPP",
    "api/v1/signatures#update" => "submitSignature",
    "api/v1/access_policies#update" => "registerAccessPolicy",
    "api/v1/access_grants#update" => "registerAccessGrant",
    "api/v1/access_grants#destroy" => "revokeAccessGrant"
  }.freeze

  # Call from a before_action to require an authenticated actor. On a write
  # with verified tokens the token also has to be bound to this request
  # (RequestBinding), and the write log gets its entry before anything changes
  # (WriteLog): a write whose evidence cannot be kept is not made.
  def authenticate_actor!
    if current_actor.blank?
      render_result("ClientNotAuthorized", text: "Missing or invalid bearer token")
      return
    end
    return if read_request? || !DidTokenVerifier.enabled?
    return unless request_bound?

    record_write_request!
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

  # Whether the token names this request in its rqh claim. Without the claim a
  # write is accepted until RequestBinding.required_from, with a header saying
  # so; after that, and with a claim that names another request, it is refused
  # like a token that does not hold. Renders and returns false when refused.
  def request_bound?
    claimed = current_actor[RequestBinding::CLAIM]
    if claimed.present?
      expected = RequestBinding.digest(request.request_method, request.original_fullpath, request.raw_post)
      return true if claimed.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(claimed, expected)

      refuse_unbound("The request hash (rqh) of this token does not match method, target and body of this " \
                     "request")
      return false
    end

    if RequestBinding.required?
      refuse_unbound("This write needs a bearer token bound to the request: an rqh claim over method, " \
                     "target and body (docs/Integrity.md section 11)")
      return false
    end

    @write_unbound = true
    response.set_header(RequestBinding::HEADER, %(missing;until="#{RequestBinding.required_from.iso8601}"))
    true
  end

  def refuse_unbound(text)
    response.set_header("WWW-Authenticate", 'Bearer error="invalid_token"')
    render_result("ClientNotAuthorized", text: text)
  end

  def write_operation = WRITE_OPERATIONS.fetch("#{controller_path}##{action_name}", "#{controller_path}##{action_name}")

  def record_write_request!
    WriteLog.request!(request_id: request.request_id, operation: write_operation, dpp_id: request.path_parameters[:dpp_id].presence,
                      issuer: actor_did, jti: current_actor["jti"], token: request.authorization.to_s.split(" ", 2).last,
                      request_hash: current_actor[RequestBinding::CLAIM], bound: !@write_unbound,
                      http_method: request.request_method, target: request.original_fullpath,
                      body_digest: RequestBinding.body_digest(request.raw_post))
    @write_logged = true
  rescue StandardError => e
    Rails.logger.error("[write-log] the request #{request.request_id} could not be recorded: #{e.class}: #{e.message}")
    render_result("ServerInternalError", text: "The write could not be recorded, so it was not made")
  end

  # When the request ends: the outcome entry of a write that has a request
  # entry. A failure here is logged; the change and its request entry stand.
  def record_write_outcome
    return unless @write_logged

    WriteLog.outcome!(request_id: request.request_id, operation: write_operation, dpp: written_dpp,
                      dpp_id: request.path_parameters[:dpp_id].presence, status: response.status)
  rescue StandardError => e
    Rails.logger.error("[write-log] the outcome of #{request.request_id} could not be recorded: #{e.class}: #{e.message}")
  end

  # The passport a write concerned, where there is one.
  def written_dpp
    dpp = instance_variable_defined?(:@dpp) ? @dpp : nil
    dpp.is_a?(Dpp) ? dpp : nil
  end

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
