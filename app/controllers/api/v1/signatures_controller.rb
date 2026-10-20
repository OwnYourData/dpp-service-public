# frozen_string_literal: true

module Api
  module V1
    # PUT /dpp/v1/dpps/{dppId}/signature -- the economic operator signs its
    # passport (docs/Integrity.md section 10).
    #
    # Not part of EN 18222:2026, which says nothing about who stands behind the
    # content of a passport. The body is a JWS in the compact serialization
    # (application/jose) over the public part of the passport in the full
    # representation, as a reader without access rights receives it; the
    # bearer token is the owner's, and the JWS names the owner's document key.
    #
    #   200  accepted, X-DPP-Signature-State: signed; a message of type Warning
    #        if the signer is not the economicOperatorId of the passport
    #   400  not such a JWS, a signature that does not verify, a payload that is
    #        not the passport as delivered now, or a passport held by a custodian
    #   401  no valid bearer token
    #   403  the token or the JWS names another DID than the owner
    #   404  no such passport
    #
    # The service checks and keeps the signature; it never signs. A refused
    # signature leaves the passport as it was.
    class SignaturesController < ApplicationController
      before_action :authenticate_actor!
      before_action :find_dpp

      def update
        return unless authorize_owner!(@dpp)

        unless DidTokenVerifier.enabled?
          return render_result("ClientForbidden",
                               text: "A signature is accepted only while bearer tokens are verified " \
                                     "(DPP_AUTH_MODE=did): it has to be the owner's")
        end

        request.body.rewind
        warnings = OperatorSignature.accept!(@dpp, request.body.read, actor: actor_did)
        report_signature(@dpp)
        render_accepted(warnings)
      rescue OperatorSignature::Refused => e
        report_signature(@dpp)
        render_result(e.status, text: "Signature refused: #{e.message}")
      end

      private

      # From the path alone: +params+ would parse the body by its Content-Type,
      # and a JWS sent as application/json is not JSON.
      def find_dpp
        @dpp = Dpp.find(request.path_parameters[:dpp_id])
      end

      # The Result object of EN 18222:2026 Table 12, with the message the
      # owner has to know about: that the signer is not the economic operator
      # the passport names.
      def render_accepted(warnings)
        messages = (warnings.empty? ? [["Info", "signature accepted"]] : warnings.map { |w| ["Warning", w] })
                   .map do |type, text|
                     { messageType: type, text: text, correlationId: request.request_id,
                       timestamp: Time.now.utc.iso8601 }
                   end
        render json: { statusCode: "Success", message: messages }, status: :ok
      end
    end
  end
end
