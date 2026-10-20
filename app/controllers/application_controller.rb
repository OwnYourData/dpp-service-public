# frozen_string_literal: true

class ApplicationController < ActionController::API
  include ApiStatus
  include ErrorHandling
  include TokenAuthenticatable
  include PayloadIntegrity
  include OperatorSignatureDelivery
  include RepresentationParam
  include AccessPolicyHeader
  include ReaderAccess
  include AccessLogging

  # A limit per client address and minute, reads and writes counted apart:
  # reading is public and cheap, writing mints DIDs and reaches custodians.
  # Configurable because the right numbers depend on who calls the instance.
  #
  # The counter lives in this process. With several replicas each keeps its
  # own, so the effective limit is the configured one times the replicas --
  # still a limit, and no shared cache to operate for it.
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new
  READ_LIMIT       = ENV.fetch("DPP_RATE_LIMIT_READ", 600).to_i
  WRITE_LIMIT      = ENV.fetch("DPP_RATE_LIMIT_WRITE", 60).to_i

  # Rails keys a limit by controller and the value of +by+; the suffix keeps the
  # two limits of one controller from sharing a counter.
  rate_limit to: READ_LIMIT, within: 1.minute, store: RATE_LIMIT_STORE,
             by: -> { "#{request.remote_ip}:read" }, with: -> { too_many_requests },
             if: -> { read_request? }
  rate_limit to: WRITE_LIMIT, within: 1.minute, store: RATE_LIMIT_STORE,
             by: -> { "#{request.remote_ip}:write" }, with: -> { too_many_requests },
             unless: -> { read_request? }

  private

  # ReadDPPIdsByProductIds is a POST because a set of identifiers does not fit
  # a URL, but it reads.
  def read_request?
    request.get? || request.head? || request.path.end_with?("/dppsByProductIds")
  end

  # 429 with Retry-After. EN 18222:2026 Table 15 has no generic status code for
  # it, so no Result object: inventing a code would be a proprietary extension.
  def too_many_requests
    response.set_header("Retry-After", "60")
    head :too_many_requests
  end
end
