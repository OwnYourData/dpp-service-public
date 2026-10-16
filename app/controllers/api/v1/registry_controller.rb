# frozen_string_literal: true

module Api
  module V1
    # EN 18222:2026 Clause 5 — Registry API for Register.
    #
    # RegisterProductDPP registers a new DPP at the EU DPP Registry, which the
    # European Commission operates under Implementing Regulation (EU) 2026/1778.
    #
    # This deployment has no connection to that registry: the Commission
    # publishes no API specification for it, and registration is not yet
    # possible for lack of a semantic catalogue. The action therefore checks the
    # entry and then says plainly that nothing was registered. It must never
    # answer with a registration identifier of its own making -- a client would
    # record the passport as registered while the registry knows nothing of it.
    class RegistryController < ApplicationController
      before_action :authenticate_actor!

      # POST /dpp/v1/registerDPP  — RegisterProductDPP (EN 18222:2026 5.2, Table 8)
      #
      # The method takes a +dppRegistryEntry+ and answers with +statusCode+ and
      # +registrationId+. EN 18222:2026 7.1 Table 11 defines the entry as the
      # passport header, of which two fields are indispensable here: the product
      # identifier and the operator. Note that EN 18222 spells the operator
      # +uniqueEconomicOperatorIdentifier+ where EN 18223 Table 1 has
      # +economicOperatorId+; both are accepted.
      def create
        payload     = request_json.to_h.with_indifferent_access
        entry       = (payload[:dppRegistryEntry] || payload).with_indifferent_access
        product_id  = entry[:uniqueProductIdentifier]
        operator_id = entry[:uniqueEconomicOperatorIdentifier] || entry[:economicOperatorId]

        if product_id.blank? || operator_id.blank?
          return render_result(
            "ClientErrorBadRequest",
            text: "dppRegistryEntry requires uniqueProductIdentifier and " \
                  "uniqueEconomicOperatorIdentifier"
          )
        end

        # 502 rather than a code outside EN 18222:2026 Table 15: the upstream
        # that would have to answer is not reachable from here. The entry is
        # checked first, so a malformed request still learns what is wrong with it.
        render_result(
          "ServerErrorBadGateway",
          text: "This service is not connected to the EU DPP Registry; " \
                "the passport has not been registered",
          code: "registry_not_connected"
        )
      end

      private

      def request_json
        request.body.rewind
        raw = request.body.read
        raw.present? ? JSON.parse(raw) : {}
      end
    end
  end
end
