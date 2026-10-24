# frozen_string_literal: true

module Api
  module V1
    # EN 18222:2026 Clause 6 — fine granular operations on individual
    # DataElements, addressed by their elementIdPath.
    #
    # EN 18222:2026 8.1 has elementIdPath follow RFC 9535 JSONPath; both methods
    # address one element, so the path is a singular query such as
    # "$.EnergyPerformance.LuminousFlux", percent-encoded into the URL. See
    # ElementIdPath for what is accepted. EN 18223:2026 Table 2 requires an
    # elementId to be unique within its level and the absolute path to be unique
    # within the passport, which is what makes this addressable at all.
    #
    # A query that is not RFC 9535 syntax, or that can select more than one
    # element, is a bad request (400); a well-formed path that leads nowhere is
    # 404.
    class DataElementsController < ApplicationController
      before_action :require_valid_representation!
      before_action :authenticate_actor!, only: %i[update]
      before_action :authenticate_reader!, only: %i[show]
      before_action :refuse_access_policy_header!, only: %i[update]
      before_action :find_dpp
      before_action :parse_element_path

      # GET /dpp/v1/dpps/:dpp_id/elements/*element_path  (6.2, Table 18)
      #
      # The path selects the element by its elementIds, so it designates the
      # same element in both representations. What comes back is that element
      # in the representation asked for: compressed, the value the path selects
      # in the compressed passport; full, the element object of Annex A.
      def show
        access   = PassportAccess.current(@dpp, reader: reader_did)
        document = access.document
        element = @element_path.resolve(document)
        if element.nil?
          return if refused_without_token?(@dpp, @element_path.leading_names)

          report_access(access) if access.controlled
          return render_result("ClientErrorResourceNotFound", text: missing_text("Element", access))
        end

        report_commitment(@dpp)
        report_access(access)
        render_element(element, document: document)
      end

      # PATCH /dpp/v1/dpps/:dpp_id/elements/*element_path  (6.3, Table 18) — RFC 7396
      #
      # The document is deep-duplicated first: +to_document+ shares its nested
      # objects with the persisted +content+, so patching in place would also
      # corrupt the snapshot written by archive_current_version! (EN 18221:2026).
      def update
        return unless authorize_owner!(@dpp)

        document = @dpp.to_document.deep_dup
        container, key = @element_path.locate(document)
        return render_result("ClientErrorResourceNotFound", text: "Element not found") if container.nil?

        container[key] = JsonMergePatch.apply(container[key], merge_patch_body)
        @dpp.apply_merge_patch!(document)
        commit_payload(@dpp)
        report_signature(@dpp)
        report_access_policy(@dpp)
        document = @dpp.to_document
        render_element(@element_path.resolve(document), document: document)
      end

      private

      def find_dpp
        @dpp = Dpp.find(params[:dpp_id])
      end

      # The glob arrives percent-decoded, so "%24.A.B" is "$.A.B" here.
      def parse_element_path
        @element_path = ElementIdPath.parse(params[:element_path])
      rescue ElementIdPath::InvalidError => e
        render_result("ClientErrorBadRequest", text: "Invalid elementIdPath: #{e.message}")
      end

      def merge_patch_body
        request.body.rewind
        raw = request.body.read
        raw.present? ? JSON.parse(raw) : {}
      end
    end
  end
end
