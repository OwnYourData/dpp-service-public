# frozen_string_literal: true

# GET /.well-known/dpp-service — docs/Delegation.md §6.
#
# Discovery, not authentication. An economic operator writing a delegation has
# to name the mandated service in `sub`; this is where they read that value
# instead of copying it out of an email. The pod never consults this endpoint:
# it learns the service's key from the DPoP proof and its identity from the
# resolvable DID, so a forged answer here buys an attacker nothing beyond
# tricking a customer into delegating to the wrong service — which is why the
# DID they end up with is resolvable and checkable on its own.
#
# Public and unauthenticated, like the read paths.
class DiscoveryController < ApplicationController
  def dpp_service
    unless ServiceDid.configured?
      return render json: { "error" => "this deployment has no service DID configured" },
                    status: :not_found
    end

    render json: ServiceDid.discovery_document, status: :ok
  end
end
