# frozen_string_literal: true

module Api
  module V1
    # Addressing a DataElementCollection directly.
    #
    # BEYOND THE PUBLISHED METHOD SET: EN 18222:2026 Table 18 defines
    # ReadDataElement and UpdateDataElement only. A collection is a subclass of
    # DataElement (EN 18223:2026 4.1.2.4) and is therefore reachable through the
    # element path; these two operations exist because addressing a top-level
    # collection by name is what clients asked for, not because the standard
    # requires them.
    class DataElementCollectionsController < ApplicationController
      before_action :require_valid_representation!
      before_action :authenticate_actor!, only: %i[update]
      before_action :authenticate_reader!, only: %i[show]
      before_action :refuse_access_policy_header!, only: %i[update]
      before_action :find_dpp

      # GET /dpp/v1/dpps/:dpp_id/collections/:element_id
      def show
        access   = PassportAccess.current(@dpp, reader: reader_did)
        document = access.document
        collection = find_collection(document, params[:element_id])
        if collection.nil?
          report_access(access) if access.controlled
          return render_result("ClientErrorResourceNotFound", text: missing_text("Collection", access))
        end

        report_commitment(@dpp)
        report_access(access)
        render_element(collection, document: document)
      end

      # PATCH /dpp/v1/dpps/:dpp_id/collections/:element_id — RFC 7396
      # Deep-duplicated first: to_document shares its nested objects with the
      # persisted content, so patching in place would also alter the snapshot
      # taken by archive_current_version! (EN 18221:2026).
      def update
        return unless authorize_owner!(@dpp)

        collections = Array(@dpp.to_document["elements"]).deep_dup
        idx = collections.find_index { |c| c["elementId"] == params[:element_id] }
        return render_result("ClientErrorResourceNotFound", text: "Collection not found") if idx.nil?

        collections[idx] = JsonMergePatch.apply(collections[idx], merge_patch_body)
        @dpp.apply_merge_patch!("elements" => collections)
        commit_payload(@dpp)
        report_access_policy(@dpp)
        render_element(collections[idx], document: @dpp.to_document)
      end

      private

      def find_dpp
        @dpp = Dpp.find(params[:dpp_id])
      end

      def find_collection(document, element_id)
        Array(document["elements"])
          .find { |c| c["elementId"] == element_id }
      end

      def merge_patch_body
        request.body.rewind
        raw = request.body.read
        raw.present? ? JSON.parse(raw) : {}
      end
    end
  end
end
