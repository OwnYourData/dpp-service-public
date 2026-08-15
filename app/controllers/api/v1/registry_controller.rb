# frozen_string_literal: true

module Api
  module V1
    # prEN 18222 Clause 5 — Registry API for Register.
    #
    # PostNewDPPToRegistry registers a new DPP at the EC registry. The registry
    # is operated by the European Commission; the concrete endpoint and schema
    # are defined by EU implementing acts. This action models the client-facing
    # contract and delegates to a (TODO) EC registry client.
    class RegistryController < ApplicationController
      before_action :authenticate_actor!

      # POST /dpp/v1/registerDPP  (§5.2, Table 8)
      def create
        payload     = request_json.to_h.with_indifferent_access
        product_id  = payload[:ProductID]
        operator_id = payload[:OperatorID]

        if product_id.blank? || operator_id.blank?
          return render_result("ClientErrorBadRequest",
                               text: "ProductID and OperatorID are required")
        end

        # TODO: call the EC registry (EN 18222 §5.1) and return its identifier.
        # registry_id = EcRegistryClient.new.register(payload)
        registry_id = "urn:ec:dpp:registry:#{SecureRandom.uuid}"

        render json: { statusCode: "SuccessCreated", registryIdentifier: registry_id },
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
