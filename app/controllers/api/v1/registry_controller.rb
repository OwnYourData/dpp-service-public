# frozen_string_literal: true

module Api
  module V1
    # EN 18222:2026 Clause 5 — Registry API for Register.
    #
    # RegisterProductDPP registers a new DPP at the EC registry. The registry
    # is operated by the European Commission; the concrete endpoint and schema
    # are defined by EU implementing acts. This action models the client-facing
    # contract and delegates to a (TODO) EC registry client.
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

        # TODO: call the EU registry and return the identifier it assigns.
        # registration_id = EcRegistryClient.new.register(entry)
        registration_id = "urn:ec:dpp:registry:#{SecureRandom.uuid}"

        render json: { statusCode: "SuccessCreated", registrationId: registration_id },
               status: :created
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
