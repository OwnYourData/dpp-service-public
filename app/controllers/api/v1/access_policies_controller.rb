# frozen_string_literal: true

module Api
  module V1
    # PUT /dpp/v1/access-policies -- register an access policy.
    #
    # Not part of EN 18222:2026, which has no notion of who may read which
    # attribute. An economic operator registers the policy of a product type
    # once (config/vocab/access-policy.schema.json); its passports then name it
    # by id in X-DPP-Access-Policy at CreateDPP or UpdateDPP.
    #
    #   201  registered
    #   200  the same policy was registered under this id before
    #   409  a different policy is registered under this id; a new version of
    #        a policy is registered under a new id
    #   400  not a valid policy
    #
    # The answer is the policy as registered.
    class AccessPoliciesController < ApplicationController
      before_action :authenticate_actor!

      def update
        body = request_json
        raise AccessPolicy::InvalidError, "the request body has to be an access policy" unless body.is_a?(Hash)

        record, created = RegisteredAccessPolicy.register!(access_policy_owner, body)
        render_dpp(record.document, status_code: created ? "SuccessCreated" : "Success")
      end

      private

      def request_json
        request.body.rewind
        raw = request.body.read
        raw.present? ? JSON.parse(raw) : nil
      end
    end
  end
end
