# frozen_string_literal: true

module Api
  module V1
    # The passport as an Asset Administration Shell: AAS V3.0, JSON, one
    # environment with the shell and its submodels (AasView, docs/AAS.md).
    #
    # Not part of EN 18222:2026. A view derived from the same passport the read
    # paths hand out, read the same way (PassportAccess): the public part
    # without a token, more for a reader with access rights, with the same
    # headers and the same entries in the access log, for a passport in this
    # service's database and for one at a custodian alike.
    #
    # The view is not covered by the signature of the economic operator, and
    # this service does not sign it either. It names the passport it comes
    # from, in the shell and in "Link: <...>; rel="via"", and says in the
    # integrity headers of the read paths what holds for that passport. A
    # client that asks for the signature (application/jose) gets 406: there is
    # none for this view, and the Link header says where the signed passport
    # is.
    class AasController < ApplicationController
      before_action :refuse_representation!
      before_action :authenticate_reader!

      # GET /dpp/v1/dpps/:dpp_id/aas
      def show
        deliver(Dpp.find(params[:dpp_id]))
      end

      # GET /dpp/v1/dppsByProductId/:product_id/aas
      def by_product_id
        deliver(Dpp.active.where(product_id: params[:product_id]).order(last_update: :desc).first!)
      end

      private

      def deliver(dpp)
        vary_on_accept!
        add_link(%(<#{source_passport_url(dpp)}>; rel="via"))
        return head(:not_acceptable) if jose_preferred?

        result = PassportAccess.current(dpp, reader: reader_did)
        report_commitment(dpp)
        report_signature(dpp)
        report_access(result)
        view = AasView.environment(result.document, aas_id: aas_view_url(dpp),
                                                    source: { "sourcePassport" => source_passport_url(dpp),
                                                              "signatureState" => OperatorSignature.state(dpp),
                                                              "payloadHash" => dpp.payload_hash })
        render json: view.to_json
      end

      # The flag of EN 18222:2026 8.1 chooses between two forms of the passport;
      # the view is always derived from the full one.
      def refuse_representation!
        return unless request.query_parameters.key?("representation")

        render_result("ClientErrorBadRequest",
                      text: "representation does not apply to the AAS view, which is always derived from the " \
                            "full representation of the passport")
      end
    end
  end
end
