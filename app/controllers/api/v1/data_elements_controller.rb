# frozen_string_literal: true

module Api
  module V1
    # prEN 18222 Clause 6 — Fine granular operations on individual DataElements
    # addressed by their absolute ElementId path (e.g. "battery/soh/value").
    class DataElementsController < ApplicationController
      before_action :authenticate_actor!, only: %i[update]
      before_action :find_dpp

      # GET /dpp/v1/dpps/:dpp_id/elements/*element_path  (§6.3, Table 10)
      def show
        element = resolve_path(@dpp.to_document, path_segments)
        return render_result("ClientErrorResourceNotFound", text: "Element not found") if element.nil?

        render_dpp(element)
      end

      # PATCH /dpp/v1/dpps/:dpp_id/elements/*element_path  (§6.5, Table 12) — RFC 7396
      #
      # The document is deep-duplicated first: +to_document+ shares its nested
      # objects with the persisted +content+, so patching in place would also
      # corrupt the snapshot written by archive_current_version! (prEN 18221).
      def update
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

      # Path is passed as a glob; split into segments (ElementId path).
      def path_segments
        params[:element_path].to_s.split("/")
      end

      # Naive nested lookup by ElementId path — replace with a proper
      # data-dictionary resolver (prEN 18223 §4.3) in production.
      def resolve_path(node, segments)
        segments.reduce(node) do |current, seg|
          break nil if current.nil?

          case current
          when Hash  then current[seg]
          when Array then current.find { |e| e.is_a?(Hash) && e["ElementId"] == seg }
          end
        end
      end

      # Writes +value+ at the given ElementId path. Mirrors resolve_path: the
      # parent may be a Hash (keyed, e.g. "DataElements") or an Array of
      # DataElements, in which case the entry is located by its ElementId.
      def assign_path(document, segments, value)
        *head, last = segments
        parent = head.empty? ? document : resolve_path(document, head)

        case parent
        when Hash
          parent[last] = value
        when Array
          index = parent.find_index { |e| e.is_a?(Hash) && e["ElementId"] == last }
          return nil if index.nil?

          parent[index] = value
        else
          return nil
        end

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
