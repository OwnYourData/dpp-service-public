# frozen_string_literal: true

module Api
  module V1
    # Access grants (AccessGrant, docs/AccessClasses.md §7). Not part of
    # EN 18222:2026, which says nothing about who may read which attribute.
    #
    # PUT /dpp/v1/access-grants -- register a grant. The body is the signed
    # grant (dpp-access-grant+jwt) as it is, with Content-Type
    # application/jwt; the bearer token is the issuer's.
    #
    #   201  registered
    #   200  this grant was registered before
    #   400  not a valid grant
    #   403  the issuer may not grant this, or the token is not the issuer's
    #   409  a different grant of this issuer is registered under its jti
    #
    # GET /dpp/v1/access-grants -- the grants the presenting DID has issued.
    #
    # DELETE /dpp/v1/access-grants/{jti} -- revoke a grant, with effect from
    # now. Only its issuer, with its own bearer token; the jti is looked up
    # under the issuer's DID.
    #
    #   200  revoked, now or before (the summary says since when)
    #   404  the presenting DID has issued no grant under this jti
    class AccessGrantsController < ApplicationController
      before_action :authenticate_actor!

      def update
        request.body.rewind
        token = request.body.read.to_s.strip
        return render_result("ClientErrorBadRequest", text: "the request body has to be an access grant") if token.empty?

        record, created = AccessGrant.register!(actor_did, token)
        render_dpp(record.summary, status_code: created ? "SuccessCreated" : "Success")
      rescue Delegation::Invalid => e
        render_result("ClientErrorBadRequest", text: "Invalid access grant: #{e.message}")
      rescue AccessGrant::Forbidden => e
        render_result("ClientForbidden", text: e.message)
      rescue AccessGrant::Conflict => e
        render_result("ClientResourceConflict", text: e.message)
      end

      def index
        grants = AccessGrant.where(issuer_did: actor_did).order(:created_at)
        render_dpp(grants.map(&:summary))
      end

      def destroy
        grant = AccessGrant.find_by(issuer_did: actor_did, jti: params[:jti].to_s)
        return render_result("ClientErrorResourceNotFound", text: "no access grant of yours under this jti") if grant.nil?

        grant.revoke!(by: actor_did)
        render_dpp(grant.reload.summary)
      end
    end
  end
end
