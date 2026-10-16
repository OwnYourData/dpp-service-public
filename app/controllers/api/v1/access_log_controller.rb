# frozen_string_literal: true

module Api
  module V1
    # The access log (AccessLog, docs/AccessClasses.md §10). Not part of
    # EN 18222:2026.
    #
    # GET /dpp/v1/access-log -- the entries that concern the presenting DID,
    # newest first: as owner, every access to its passports and every read
    # this service made at a custodian for them; as reader, its own accesses;
    # as issuer, its grants registered and revoked and the reads made under
    # them. Nobody gets everything over the API; the operator reads the whole
    # log in the cluster (bin/rails dpp:access:log).
    #
    # Filters: dppId, event, since, until (ISO 8601). Pages: limit (default
    # 100, at most 1000) and after (the "next" of the previous page).
    #
    #   200  { "entries": [...], "next": "<cursor>" }   next only if there is more
    #   400  a filter that is not valid
    #   401  no valid bearer token
    #   403  tokens are not verified on this instance
    class AccessLogController < ApplicationController
      before_action :authenticate_actor!

      def index
        unless DidTokenVerifier.enabled?
          return render_result("ClientForbidden", text: "the access log is only available with verified tokens")
        end

        limit = (params[:limit].presence || AccessLog::DEFAULT_PAGE).to_i.clamp(1, AccessLog::MAX_PAGE)
        page = AccessLog.entries(did: actor_did, dpp_id: params[:dppId], event: event_param,
                                 since: time_param(:since), until_time: time_param(:until),
                                 after: cursor_param, limit: limit + 1).to_a
        more = page.size > limit
        page = page.first(limit)
        render_dpp({ "entries" => page.map(&:summary), "next" => more ? page.last.id.to_s : nil }.compact)
      rescue ArgumentError => e
        render_result("ClientErrorBadRequest", text: e.message)
      end

      private

      def event_param
        event = params[:event].presence
        return nil if event.nil?
        raise ArgumentError, "event has to be one of #{AccessEvent::EVENTS.join(', ')}" unless AccessEvent::EVENTS.include?(event)

        event
      end

      def time_param(name)
        value = params[name].presence
        value && Time.iso8601(value).utc
      rescue ArgumentError
        raise ArgumentError, "#{name} has to be a time in ISO 8601"
      end

      def cursor_param
        value = params[:after].presence
        return nil if value.nil?
        raise ArgumentError, "after has to be the next of a previous page" unless value.match?(/\A\d+\z/)

        value
      end
    end
  end
end
