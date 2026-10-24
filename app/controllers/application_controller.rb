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
  # The counts live in the database (RateCounter), which every replica shares,
  # so the limit holds for the service as a whole however many replicas run,
  # and for all operations of a kind together.
  READ_LIMIT  = ENV.fetch("DPP_RATE_LIMIT_READ", 600).to_i
  WRITE_LIMIT = ENV.fetch("DPP_RATE_LIMIT_WRITE", 60).to_i
  RATE_WINDOW = 60

  before_action :enforce_rate_limit

  private

  def enforce_rate_limit
    kind, limit = read_request? ? ["read", READ_LIMIT] : ["write", WRITE_LIMIT]
    too_many_requests if RateCounter.hit!("#{request.remote_ip}:#{kind}", within: RATE_WINDOW) > limit
  end

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
