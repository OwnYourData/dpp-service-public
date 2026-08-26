# frozen_string_literal: true

module Api
  module V1
    # EN 18222:2026 Clause 6 — fine granular operations on individual
    # DataElements, addressed by their absolute element path.
    #
    # The path is the elementId of each level, separated by "/", e.g.
    # "performanceMetrics/maxPressure". EN 18223:2026 Table 2 requires an
    # elementId to be unique within its level and the absolute path to be unique
    # within the passport, which is what makes this addressable at all.
    #
    # DEVIATION: EN 18222:2026 8.1 asks for RFC 9535 JSONPath in elementIdPath.
    # This is a path of element identifiers instead -- shorter, and all the fine
    # granular methods need. JSONPath is not implemented.
    class DataElementsController < ApplicationController
      before_action :authenticate_actor!, only: %i[update]
      before_action :find_dpp

      # GET /dpp/v1/dpps/:dpp_id/elements/*element_path  (6.2, Table 18)
      def show
        element = resolve_path(@dpp.to_document, path_segments)
        return render_result("ClientErrorResourceNotFound", text: "Element not found") if element.nil?

        render_dpp(element)
      end

      # PATCH /dpp/v1/dpps/:dpp_id/elements/*element_path  (6.3, Table 18) — RFC 7396
      #
      # The document is deep-duplicated first: +to_document+ shares its nested
      # objects with the persisted +content+, so patching in place would also
      # corrupt the snapshot written by archive_current_version! (EN 18221:2026).
      def update
        return unless authorize_owner!(@dpp)

        document = @dpp.to_document.deep_dup
        element  = resolve_path(document, path_segments)
        return render_result("ClientErrorResourceNotFound", text: "Element not found") if element.nil?

        assign_path(document, path_segments, JsonMergePatch.apply(element, merge_patch_body))
        @dpp.apply_merge_patch!(document)
        render_dpp(resolve_path(@dpp.to_document, path_segments))
      end

      private

      def find_dpp
        @dpp = Dpp.find(params[:dpp_id])
      end

      # Path is passed as a glob; split into element identifiers.
      def path_segments
        params[:element_path].to_s.split("/")
      end

      # Walk down one level per segment. Every level -- the passport itself and
      # every DataElementCollection or MultiValuedDataElement below it -- holds
      # its children in "elements" (EN 18223:2026 Annex A), so the descent is
      # the same at every depth.
      #
      # A proper data-dictionary resolver would additionally validate each
      # elementId against the dictionary its dictionaryReference names; this
      # walks the document structurally.
      def resolve_path(node, segments)
        segments.reduce(node) do |current, seg|
          break nil if current.nil?

          children = current.is_a?(Hash) ? current["elements"] : current
          children.is_a?(Array) ? children.find { |e| e.is_a?(Hash) && e["elementId"] == seg } : nil
        end
      end

      # Replaces the element at the given path. The parent always holds its
      # children in "elements", so only the last segment has to be located.
      def assign_path(document, segments, value)
        *head, last = segments
        parent = head.empty? ? document : resolve_path(document, head)
        return nil unless parent.is_a?(Hash)

        children = parent["elements"]
        return nil unless children.is_a?(Array)

        index = children.find_index { |e| e.is_a?(Hash) && e["elementId"] == last }
        return nil if index.nil?

        children[index] = value
        document
      end

      def merge_patch_body
        request.body.rewind
        raw = request.body.read
        raw.present? ? JSON.parse(raw) : {}
      end
    end
  end
end
