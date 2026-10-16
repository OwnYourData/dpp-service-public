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
# The reader DIDs (ReaderDid) are listed under "readers", one entry per pod:
# { "pod": <base URL of the pod>, "did": <reader DID> }. The intermediary enters
# the reader DID of its environment as a fixed value and compares it with this
# list; it does not take it from here. Without configured readers the member is
# left out.
#
# The issuers this service takes an access grant for the class "authority"
# from (AuthorityIssuers) are listed under "authorityIssuers", so that whoever
# relies on the controlled part being kept from everyone else can see whose
# word it rests on. Without configured issuers the member is left out.
#
# Public and unauthenticated, like the read paths.
class DiscoveryController < ApplicationController
  def dpp_service
    unless ServiceDid.configured?
      return render json: { "error" => "this deployment has no service DID configured" },
                    status: :not_found
    end

    document = ServiceDid.discovery_document
    readers  = ReaderDid.discovery_entries
    document = document.merge("readers" => readers) if readers
    issuers  = AuthorityIssuers.all
    document = document.merge("authorityIssuers" => issuers) if issuers.any?

    render json: document, status: :ok
  end
end
