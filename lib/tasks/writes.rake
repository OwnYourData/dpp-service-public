# frozen_string_literal: true

namespace :dpp do
  namespace :writes do
    # The write log of one passport, for its owner (docs/Integrity.md section
    # 11): every entry as a line of JSON, oldest first, the spent tokens
    # included. The owner checks it with bin/verify_writes. Not reachable over
    # the API.
    #
    #   bin/rails dpp:writes:export DPP=<passport identifier> [SINCE=<ISO 8601>] > writes.jsonl
    desc "Print the write log of one passport as JSON lines, oldest first"
    task export: :environment do
      dpp_id = ENV["DPP"].to_s.strip
      abort("DPP is required") if dpp_id.empty?

      since = ENV["SINCE"].presence && Time.iso8601(ENV["SINCE"]).utc
      WriteLog.export(dpp_id: dpp_id, since: since).each { |entry| puts entry.export.to_json }
    end

    # Removes the entries older than the retention period
    # (DPP_WRITE_LOG_RETENTION_DAYS, ten years by default) that name no
    # passport, or a passport of which neither the passport nor an archived
    # version is left. The one way entries leave the log.
    #
    #   bin/rails dpp:writes:prune
    desc "Remove write log entries older than the retention period whose passport is gone"
    task prune: :environment do
      removed = WriteLog.prune!
      puts "#{removed} entries older than #{WriteLog::RETENTION_DAYS} days removed"
    end
  end
end
