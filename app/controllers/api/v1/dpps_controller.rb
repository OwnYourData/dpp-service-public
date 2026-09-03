# frozen_string_literal: true

module Api
  module V1
    # EN 18222:2026 Clause 4 — Life Cycle API (Main Methods).
    class DppsController < ApplicationController
      # Reads of public data are unauthenticated; writes require an actor.
      before_action :authenticate_actor!,
                    only: %i[create update destroy move_custody
                             show_delegation renew_delegation]
      before_action :find_dpp, only: %i[show update destroy move_custody
                                        show_delegation renew_delegation]

      # POST /dpp/v1/dpps  — CreateDPP (§4.6, Table 5)
      #
      # DID handling keyed off digitalProductPassportId (no proprietary fields):
      #   * omitted        -> Variante A: the service mints a did:oyd and keeps
      #                       its keys (EN 18219:2026 / oydid). Standard-conform:
      #                       CreateDPP returns the assigned dpp ID (Table 5).
      #   * did:oyd:...     -> client-supplied DID (Variante B). Resolved
      #                       before use: it must be live and its
      #                       serviceEndpoint must name the host that will
      #                       hold the passport (DidOyd.assert_endpoint_host!).
      #   * other URI/URL   -> stored as-is (unchanged behaviour).
      #
      # Storage backend (S2), keyed off the X-DPP-Storage header — deliberately
      # a header and not a field of the DPP document, so the payload stays free
      # of proprietary attributes (EN 18223:2026):
      #   * absent  -> the document is stored in this service's database
      #   * present -> the document is stored in the hosting pod named by the
      #                token; the pod also serves the public read paths, so the
      #                DID's serviceEndpoint points at it. The carrier does not:
      #                it bears the product identifier, whose host is the operator's.
      def create
        storage = pod_storage_param     # nil unless X-DPP-Storage is present
        dpp = Dpp.from_document(dpp_document_param)

        # The product identifier is what the carrier bears (EN 18219:2026
        # 3.1.25, 4.5.2 (1)), so it is checked before anything permanent happens:
        # minting first and failing validation afterwards would leave an orphan
        # DID behind. granularity is checked against the path rather than
        # trusted (EN 18223:2026 Table 1).
        if dpp.product_id.present?
          begin
            ProductIdentifier.parse!(dpp.product_id).assert_granularity!(dpp.granularity)
          rescue ProductIdentifier::InvalidError => e
            return render_result("ClientErrorBadRequest", text: e.message)
          end
        end

        # The mandate names one passport (D2). That name has to be the one of
        # the passport being created, otherwise the delegation is redeemable but
        # not for this object — a mismatch the pod would only notice at the
        # first write, after a DID had already been minted.
        storage&.ensure_product!(dpp.product_id)

        # Reachability and credentials are verified BEFORE anything permanent
        # happens — a DID whose serviceEndpoint points at an unreachable pod
        # could only be corrected with a DID update.
        storage&.reachable!

        # A client-supplied did:oyd (Variante B) is checked before anything
        # permanent happens: it has to resolve, and its serviceEndpoint has to
        # name the host that will actually hold this passport. Both are
        # unrepairable later, because this service holds no key for a DID it
        # did not mint and therefore cannot update the endpoint.
        if dpp.dpp_id.to_s.start_with?("did:oyd:")
          begin
            DidOyd.assert_endpoint_host!(dpp.dpp_id,
                                         storage ? storage.base_url : DidOyd.endpoint_base)
          rescue DidOyd::DidError => e
            return render_result("ClientErrorBadRequest", text: e.message)
          end
        end

        # Owner comes from the verified token, never from the payload; nil in
        # permissive mode, where there is no verified identity to record.
        dpp.owner_did = actor_did if DidTokenVerifier.enabled?
        dpp.assign_pod_storage!(storage) if storage

        if dpp.dpp_id.blank?
          if dpp.product_id.blank?
            return render_result("ClientErrorBadRequest",
                                 text: "uniqueProductIdentifier is required to mint a DID")
          end
          minted = if storage
                     DidOyd.mint(dpp.product_id, endpoint_base: storage.base_url)
                   else
                     DidOyd.mint(dpp.product_id)
                   end
          dpp.assign_minted_did!(minted)
        end

        dpp.save!
        begin
          dpp.store_in_pod!
        rescue PodStorage::Error
          # Roll back so no half-created passport is left behind: the DID is
          # revoked (only possible for a service-minted one) and the row goes.
          rollback_failed_pod_create(dpp)
          raise
        end

        render_dpp(dpp.to_document, status_code: "SuccessCreated")
      end

      # GET /dpp/v1/dpps/:dpp_id  — ReadDPPById (§4.2, Table 1)
      def show
        render_dpp(@dpp.to_document)
      end

      # PATCH /dpp/v1/dpps/:dpp_id  — UpdateDPP, RFC 7396 (§4.7, Table 6)
      def update
        return unless authorize_owner!(@dpp)

        @dpp.apply_merge_patch!(merge_patch_body)
        render_dpp(@dpp.to_document)
      end

      # DELETE /dpp/v1/dpps/:dpp_id  — DeleteDPPById (§4.8, Table 7)
      #
      # The active passport is removed, but its history is kept: the final
      # snapshot is written with dppStatus "Archived" and remains retrievable
      # via ReadDPPVersionByIdAndDate (EN 18221:2026 4.2).
      #
      # For a service-minted DID (Variante A) the DID is revoked first, using
      # the stored keys; a revocation failure aborts before anything is deleted.
      def destroy
        return unless authorize_owner!(@dpp)

        if @dpp.did_managed?
          DidOyd.revoke(@dpp.dpp_id, doc_key: @dpp.did_doc_key, rev_key: @dpp.did_rev_key)
        end
        @dpp.update!(dpp_status: "Archived")
        @dpp.archive_current_version!   # no-op for a pod-backed DPP

        if @dpp.pod?
          # Write the final "Archived" state, then soft-delete in the pod: the
          # public paths answer 404 afterwards, the history survives.
          @dpp.store_in_pod!
          @dpp.pod_storage.delete_object(@dpp.storage_object_id) if @dpp.storage_object_id.present?
        end

        @dpp.destroy!
        render_dpp(nil, status_code: "SuccessNoContent")
      end

      # POST /dpp/v1/dpps/:dpp_id/custody  — change the custodian.
      #
      # Not part of EN 18222:2026: the standard describes what a service does with
      # a passport, not where it keeps it. This is the operation the exit claim
      # rests on. Custody is delegated per passport, so moving it is the same
      # kind of act as granting it: the new mandate arrives in X-DPP-Storage
      # exactly as at CreateDPP, and a delegation issued for the old custodian
      # does not hold at the new pod -- that is the property, not an obstacle.
      #
      # The previous custodian keeps serving unless +release_previous+ is set.
      # Three reasons: the overlap is the rollback path while a printed carrier
      # may still resolve to the old host; withdrawing custody is a declaration
      # of the holder and should look like one; and the version history lives in
      # the pod, so releasing before the new custodian has been seen to answer
      # would discard what EN 18221:2026, 4.3 requires to be retained.
      #
      # What "release" can and cannot be: a delegated token soft-deletes the
      # object -- the public paths answer 404, the payload versions remain.
      # Erasure needs admin rights at that pod and is a matter between holder
      # and custodian, outside the mandate. The architecture can enforce exit;
      # it cannot enforce forgetting.
      def move_custody
        return unless authorize_owner!(@dpp)

        unless @dpp.pod?
          return render_result("ClientErrorBadRequest",
                               text: "This passport is not held by a custodian")
        end

        storage = pod_storage_param
        if storage.nil?
          return render_result(
            "ClientErrorBadRequest",
            text: "X-DPP-Storage carrying the new custodian's delegation is required"
          )
        end

        if storage.base_url.to_s == @dpp.storage_base_url.to_s &&
           storage.collection_id.to_s == @dpp.storage_collection_id.to_s
          return render_result("ClientErrorBadRequest",
                               text: "The passport is already held there")
        end

        # Both checks happen before anything permanent: a mandate that does not
        # cover creation, or a pod that cannot be reached, must not leave the
        # passport pointing at a custodian that never received it.
        storage.ensure_covers!("create")
        storage.reachable!

        previous = @dpp.move_to_pod!(storage)
        released = release_previous? ? release_custody(previous) : false

        Rails.logger.info(
          "[custody] #{@dpp.dpp_id} moved from #{previous[:base_url]} " \
          "collection #{previous[:collection_id]} to #{storage.base_url} " \
          "collection #{storage.collection_id}, previous released=#{released}"
        )

        render_dpp(@dpp.to_document)
      end

      # GET /dpp/v1/dpps/:dpp_id/delegation  — which mandate this service holds
      # for this passport.
      #
      # The holder keeps its own record of what it signed, but until now had no
      # way to ask what the service actually holds. The two drift apart after a
      # restore from an older backup, and the drift is silent: the holder counts
      # a passport as provided for while the service sits on an expired mandate.
      # This makes that state readable.
      #
      # An account of our own state, not an authorisation: the claims are read
      # with Delegation.peek and nothing about them is checked, because an
      # expired or otherwise unusable mandate is precisely what the caller is
      # here to find out about. Nothing secret is disclosed -- all five values
      # were signed by the owner, who is the only one allowed to read them.
      #
      # Both are nil when the stored mandate cannot be read at all, which is the
      # same answer in a different shape: the service holds nothing it could
      # redeem, and the holder has to send a fresh one.
      def show_delegation
        return unless authorize_owner!(@dpp)

        unless @dpp.pod?
          return render_result("ClientErrorResourceNotFound",
                               text: "This passport is not held by a custodian, " \
                                     "so there is no delegation for it")
        end

        claims = Delegation.peek(@dpp.storage_delegation) || {}
        render_dpp({
                     "jti"        => claims["jti"],
                     "exp"        => claims["exp"],
                     "act"        => claims["act"],
                     "collection" => claims["collection"],
                     "base_url"   => claims["aud"]
                   })
      end

      # POST /dpp/v1/dpps/:dpp_id/delegation  — replace the mandate under which
      # this service holds the passport at its custodian.
      #
      # Not part of EN 18222:2026, for the same reason as custody: the standard
      # says what a service does with a passport, not on whose authority it
      # reaches the store it keeps it in. A mandate has a lifetime (§10) and a
      # passport does not, so the mandate outlives its usefulness long before
      # the passport does and there has to be a way to hand over a fresh one.
      #
      # Why an operation of its own rather than X-DPP-Storage on PATCH: PATCH
      # carries RFC 7396 semantics over the document (EN 18222:2026, Table 6).
      # Replacing a mandate is an act about custody, not a field of the
      # passport; two meanings in one call would blur both, and the client saves
      # exactly one request.
      #
      # The stored mandate is deliberately NOT consulted for authority here --
      # the ordinary reason to be on this path is that it has expired. What it
      # is still read for, without being trusted, is the comparison in the two
      # rules below; if it is no longer even readable, those two are skipped.
      def renew_delegation
        return unless authorize_owner!(@dpp)

        unless @dpp.pod?
          return render_result("ClientErrorBadRequest",
                               text: "This passport is not held by a custodian")
        end

        storage = pod_storage_param
        if storage.nil?
          return render_result("ClientErrorBadRequest",
                               text: "X-DPP-Storage carrying the fresh delegation is required")
        end

        # A mandate for somewhere else is a change of custodian, which moves the
        # document and is therefore a different act with a different endpoint.
        unless same_custody?(storage)
          return render_result(
            "ClientErrorBadRequest",
            text: "The delegation names a different collection or custodian; " \
                  "handing the passport to another one is POST /dpps/{dppId}/custody"
          )
        end

        storage.ensure_product!(@dpp.product_id)
        return unless delegation_widens_or_matches?(storage)

        # Before anything is overwritten: fetch a real token. It is the only
        # evidence that the fresh mandate is redeemable, and a broken one must
        # never replace a working one.
        storage.reachable!

        @dpp.update!(storage_delegation: storage.storage_delegation)
        Rails.logger.info(
          "[delegation] #{@dpp.dpp_id} renewed at #{@dpp.storage_base_url} " \
          "collection #{@dpp.storage_collection_id}, jti " \
          "#{storage.delegation_claims['jti']}, exp #{storage.delegation_claims['exp']}"
        )

        # 204 rather than the Result object of EN 18222:2026 Table 12: that
        # object is the answer to a failed execution (7.2), and the passport
        # itself is untouched by this call -- returning the document would
        # suggest otherwise and would mean reading it back out of the pod for
        # nothing. Everything a client could learn from a body -- product, act,
        # exp -- it signed itself moments earlier. Failures do use the Result
        # object, mapped per docs/Delegation.md §15.
        render_dpp(nil, status_code: "SuccessNoContent")
      end

      # GET /dpp/v1/dppsByProductId/:product_id  — ReadDPPByProductId (§4.3, Table 2)
      def by_product_id
        dpp = Dpp.active.where(product_id: params[:product_id]).order(last_update: :desc).first!
        render_dpp(dpp.to_document)
      end

      # GET /dpp/v1/dppsByIdAndDate/:dpp_id?date=
      # ReadDPPVersionByIdAndDate (EN 18222:2026 4.4, Table 3 and Table 16)
      #
      # The version that was current at +date+ is the earliest snapshot archived
      # at or after that date. If none exists, the passport has not changed
      # since -- so the live one is returned. No join on dpps: archived versions
      # outlive a deleted passport.
      # For a pod-backed passport the history lives in the pod (which archives
      # every change on its own), so the lookup is delegated there.
      def by_id_and_date
        date   = Time.iso8601(params.require(:date)).utc
        dpp_id = params[:dpp_id]

        pod_dpp = Dpp.where(dpp_id: dpp_id, storage_backend: "pod").first
        if pod_dpp
          document = pod_dpp.pod_storage.version_at(dpp_id, date)
          raise ActiveRecord::RecordNotFound if document.nil?

          return render_dpp(document)
        end

        version = DppVersion.where(dpp_id: dpp_id)
                            .where(archived_at: date..)
                            .order(:archived_at).first
        document = version&.content || Dpp.active.find(dpp_id).to_document
        render_dpp(document)
      rescue ArgumentError
        render_result("ClientErrorBadRequest", text: "Invalid 'date' (expected ISO 8601 UTC)")
      end

      # POST /dpp/v1/dppsByProductIds  — ReadDPPIdsByProductIds (§4.5, Table 4)
      # AND-match of the supplied product identifiers, with cursor pagination.
      def ids_by_product_ids
        product_ids = Array(request_json)
        return render_result("ClientErrorBadRequest", text: "Body must be a non-empty array") if product_ids.empty?

        limit  = [params.fetch(:limit, 100).to_i, 1000].min
        cursor = params[:cursor].presence

        relation = Dpp.where(product_id: product_ids).order(:dpp_id)
        relation = relation.where("dpp_id > ?", cursor) if cursor
        page = relation.limit(limit + 1).pluck(:dpp_id)

        next_cursor = page.size > limit ? page[limit - 1] : nil
        render json: { statusCode: "Success", payload: page.first(limit), nextCursor: next_cursor }
      end

      private

      def find_dpp
        @dpp = Dpp.find(params[:dpp_id])
      end

      # Storage configuration from the X-DPP-Storage header, or nil for local
      # storage. The header carries { base_url, collection_id, delegation }
      # (docs/Delegation.md §9); the delegation is verified on the way in, so a
      # mandate for another service, another pod or another collection is
      # refused here rather than at the first write.
      #
      # Raises PodStorage::ConfigError (-> 400) if the header is malformed and
      # PodStorage::DelegationError (-> 401/403 per §15) if the mandate does not
      # hold.
      def pod_storage_param
        raw = request.headers["X-DPP-Storage"].presence
        return nil if raw.nil?

        PodStorage.from_header(raw)
      end

      # Same custodian, same collection -- the condition for a renewal as
      # opposed to a handover. Read from the columns, never from the stored
      # mandate: on this path that one may be long expired.
      def same_custody?(storage)
        storage.base_url.to_s == @dpp.storage_base_url.to_s &&
          storage.collection_id.to_s == @dpp.storage_collection_id.to_s
      end

      # Two guards against the most likely mistake on this path, which is
      # handing over the wrong artefact: a mandate that grants less than the one
      # in place, or one that runs out no later. Both are compared against the
      # stored claims read WITHOUT verification -- they are not being trusted for
      # authority, only for the comparison, and an expired mandate still has to
      # be readable for it. A mandate that can no longer be parsed leaves
      # nothing to compare against, so both checks fall away.
      def delegation_widens_or_matches?(storage)
        stored = Delegation.peek(@dpp.storage_delegation)
        return true if stored.nil?

        fresh   = storage.delegation_claims
        dropped = Array(stored["act"]).map(&:to_s) - Array(fresh["act"]).map(&:to_s)
        if dropped.any?
          Rails.logger.info(
            "[delegation] #{@dpp.dpp_id} renewal refused, insufficient_scope: " \
            "the fresh mandate drops #{dropped.inspect}"
          )
          render_result("ClientForbidden",
                        text: "The fresh delegation does not cover " \
                              "#{dropped.join(', ')}, which the stored one does")
          return false
        end

        if fresh["exp"].to_i <= stored["exp"].to_i
          render_result("ClientErrorBadRequest",
                        text: "The fresh delegation expires no later than the stored one")
          return false
        end

        true
      end

      # Opt-in: end custody at the previous pod in the same call. Off by
      # default, because it removes the rollback path and is a declaration in
      # its own right.
      def release_previous?
        ActiveModel::Type::Boolean.new.cast(params[:release_previous]) == true
      end

      # Soft-delete at the previous custodian, under the mandate that was
      # issued for it. A failure here is logged and reported, but does not undo
      # the move: the passport has already arrived at the new custodian, and
      # leaving it in limbo would be worse than leaving a copy behind.
      def release_custody(previous)
        object_id = previous[:object_id]
        return false if object_id.blank?

        previous[:storage].ensure_covers!("delete")
        previous[:storage].delete_object(object_id)
        true
      rescue PodStorage::Error => e
        Rails.logger.error("[custody] previous custodian not released: #{e.message}")
        false
      end

      # CreateDPP failed while talking to the pod: undo what we already did so
      # the client can simply retry.
      def rollback_failed_pod_create(dpp)
        if dpp.did_managed?
          begin
            DidOyd.revoke(dpp.dpp_id, doc_key: dpp.did_doc_key, rev_key: dpp.did_rev_key)
          rescue DidOyd::DidError => e
            Rails.logger.error("[dpp] could not revoke #{dpp.dpp_id} after a failed " \
                               "pod write: #{e.message}")
          end
        end
        dpp.destroy!
      rescue StandardError => e
        Rails.logger.error("[dpp] rollback after failed pod write incomplete: #{e.message}")
      end

      # The DPP document (EN 18223:2026 attributes) from the request body.
      def dpp_document_param
        body = request_json
        raise ActionController::ParameterMissing, :dpp if body.blank?

        body
      end

      def merge_patch_body
        request_json || {}
      end

      def request_json
        @request_json ||= begin
          request.body.rewind
          raw = request.body.read
          raw.present? ? JSON.parse(raw) : nil
        end
      end
    end
  end
end
