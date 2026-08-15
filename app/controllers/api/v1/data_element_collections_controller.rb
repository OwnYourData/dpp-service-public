# frozen_string_literal: true

module Api
  module V1
    # prEN 18222 Clause 6 — Fine granular operations on DataElementCollections.
    class DataElementCollectionsController < ApplicationController
      before_action :authenticate_actor!, only: %i[update]
      before_action :find_dpp

      # GET /dpp/v1/dpps/:dpp_id/collections/:element_id  (§6.2, Table 9)
      def show
        collection = find_collection(params[:element_id])
        return render_result("ClientErrorResourceNotFound", text: "Collection not found") if collection.nil?

        render_dpp(collection)
      end

      # PATCH /dpp/v1/dpps/:dpp_id/collections/:element_id  (§6.4, Table 11) — RFC 7396
      # Deep-duplicated first: to_document shares its nested objects with the
      # persisted content, so patching in place would also alter the snapshot
      # taken by archive_current_version! (prEN 18221).
      def update
        collections = Array(@dpp.to_document["dataElementCollections"]).deep_dup
        idx = collections.find_index { |c| c["ElementId"] == params[:element_id] }
        return render_result("ClientErrorResourceNotFound", text: "Collection not found") if idx.nil?

        collections[idx] = JsonMergePatch.apply(collections[idx], merge_patch_body)
        @dpp.apply_merge_patch!("dataElementCollections" => collections)
        render_dpp(collections[idx])
      end

      private

      def find_dpp
        @dpp = Dpp.find(params[:dpp_id])
      end

      def find_collection(element_id)
        Array(@dpp.to_document["dataElementCollections"])
          .find { |c| c["ElementId"] == element_id }
      end

      def merge_patch_body
        request.body.rewind
        raw = request.body.read
        raw.present? ? JSON.parse(raw) : {}
      end
    end
  end
end
