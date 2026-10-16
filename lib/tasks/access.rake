# frozen_string_literal: true

namespace :dpp do
  namespace :access do
    # Local passports with an access policy that are still kept whole -- from
    # before such passports were split -- are split into a public and a
    # controlled part, and their payload is committed again, because what a
    # reader without access rights gets has changed. Names the passports, never
    # their content. Without them, nothing happens.
    #
    #   bin/rails dpp:access:split_local
    desc "Split local passports with an access policy that are still kept whole, and commit them again"
    task split_local: :environment do
      passports = Dpp.where(storage_backend: "local").where.not(access_policy_id: nil)
                     .select { |dpp| dpp.controlled_content.blank? }
      puts "#{passports.size} local passport(s) with an access policy kept whole"
      passports.each do |dpp|
        dpp.split_locally!
        state = PayloadCommitment.call(dpp)
        puts "#{dpp.dpp_id}: split, commitment #{state || 'not applicable'}"
      end
    end

    # The whole access log, for the operator: one entry per line as JSON,
    # newest first, with the filters of GET /dpp/v1/access-log and DID= for
    # the entries that concern one DID. Without LIMIT the 100 newest.
    #
    #   bin/rails dpp:access:log [DPP=…] [EVENT=…] [SINCE=…] [UNTIL=…] [DID=…] [LIMIT=…] [AFTER=…]
    desc "Print the access log as JSON lines, newest first"
    task log: :environment do
      time = ->(name) { ENV[name].presence && Time.iso8601(ENV[name]).utc }
      entries = AccessLog.entries(did: ENV["DID"].presence, dpp_id: ENV["DPP"].presence,
                                  event: ENV["EVENT"].presence, since: time.call("SINCE"),
                                  until_time: time.call("UNTIL"), after: ENV["AFTER"].presence,
                                  limit: (ENV["LIMIT"].presence || AccessLog::DEFAULT_PAGE).to_i)
      entries.each { |entry| puts entry.summary.to_json }
    end

    # Revokes an access grant on order, as operator: with effect from now,
    # logged with the reason, which is required. The issuer and the owner
    # see it in their access log.
    #
    #   bin/rails dpp:access:revoke ISSUER=<issuer DID> JTI=<jti> REASON="<order, reference>"
    desc "Revoke an access grant as operator, with a reason"
    task revoke: :environment do
      issuer, jti, reason = ENV.values_at("ISSUER", "JTI", "REASON").map { |v| v.to_s.strip }
      abort("ISSUER, JTI and REASON are required") if [issuer, jti, reason].any?(&:empty?)

      grant = AccessGrant.find_by(issuer_did: issuer, jti: jti)
      abort("no access grant of #{issuer} under jti #{jti}") if grant.nil?

      if grant.revoke!(by: "operator", reason: reason)
        puts "revoked: #{issuer} #{jti}, at #{grant.reload.revoked_at.iso8601}"
      else
        puts "revoked before: #{issuer} #{jti}, at #{grant.revoked_at.iso8601} by #{grant.revoked_by}"
      end
    end

    # Removes the entries of the access log older than the retention period
    # (DPP_ACCESS_LOG_RETENTION_DAYS, five years by default). The one way
    # entries leave the log.
    #
    #   bin/rails dpp:access:prune
    desc "Remove access log entries older than the retention period"
    task prune: :environment do
      removed = AccessLog.prune!
      puts "#{removed} entries older than #{AccessLog::RETENTION_DAYS} days removed"
    end
  end
end
