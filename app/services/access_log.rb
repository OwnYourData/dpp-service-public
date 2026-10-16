# frozen_string_literal: true

# The access log (docs/AccessClasses.md §10): who read what of the controlled
# part of a passport, who was refused, which reads this service made at a
# custodian under its own read grant, and which access grants were registered
# and revoked. Never content, never tokens, never signed statements.
#
# Entries of a request are collected while it runs and written when it ends
# (AccessLogging), with the HTTP status it ended with:
#
#   read            a reader with access rights read a passport (PassportAccess)
#   integrityError  the same, but the controlled part did not match its digest
#                   and nothing of it was handed out
#   refused         a reader with a verified token, without a valid access
#                   right, read a passport that has an access policy
#   serviceRead     a read at a custodian under this service's read grant that
#                   no reader caused: looking up the controlled card
#                   (lookup), reading it again before a mismatch is final
#                   (retry), searching the versions of a controlled card
#                   (version), the measurement task (measure), anything else
#                   (internal)
#   grantRegistered an access grant was registered
#   grantRevoked    an access grant was revoked, by its issuer or the operator
#
# Every read under the read grant has exactly one entry: the one that
# delivered the controlled part to a reader belongs to that reader's entry,
# every other one is a serviceRead. This is what lines the log up with the
# custodian's own trail of the reads it served this service: object id and
# time.
#
# Who sees an entry is kept with it (AccessEventParty): the owner of the
# passport, the reader, the issuers of the grants it was read under. The
# operator sees everything, through the rake tasks, not through the API.
#
# Entries are only ever added (AccessEvent). After the retention period
# (DPP_ACCESS_LOG_RETENTION_DAYS, five years by default) the operator prunes
# them with prune!.
module AccessLog
  KEY         = :dpp_access_log
  PURPOSE_KEY = :dpp_access_log_purpose

  RETENTION_DAYS = ENV.fetch("DPP_ACCESS_LOG_RETENTION_DAYS", 1826).to_i

  MAX_PAGE     = 1000
  DEFAULT_PAGE = 100

  # The paths at a custodian that hand out the content of a controlled card.
  CONTENT_READ = %r{\A/object/[^/?]+/read\z|\A/dpp/v1/controlled/dppsByIdAndDate/}
  LOOKUP       = %r{\A/collection/|\A/object/[^/?]+(?:/meta)?\z}
  VERSIONS     = %r{\A/dpp/v1/controlled/dpps/[^?]+/versions\z}

  Context = Struct.new(:request_id, :operation, :accesses, :pod_reads, keyword_init: true)

  module_function

  # Opens the log of a request.
  def open(request_id:, operation:)
    Thread.current[KEY] = Context.new(request_id: request_id, operation: operation, accesses: [], pod_reads: [])
  end

  def current = Thread.current[KEY]

  # Writes what the request collected; +status+ is the HTTP status it ended
  # with. The context is gone afterwards, whether writing worked or not.
  def close!(status:)
    context = Thread.current[KEY]
    Thread.current[KEY] = nil
    write(context, status) if context
  end

  # Whether the open request has handed out, or tried to hand out, the
  # controlled part to a reader. Such an answer is not sent unless its entry
  # is written.
  def controlled_read? = current.present? && current.accesses.any? { |entry| entry[:event] != "refused" }

  # Runs the block inside a context, opening one -- and writing it at the end
  # -- if none is open (a read outside a request).
  def within
    return yield if current

    open(request_id: nil, operation: nil)
    begin
      yield
    ensure
      close!(status: nil)
    end
  end

  # Marks the reads under the read grant inside the block, outside a request,
  # with +purpose+ (the measurement task).
  def with_purpose(purpose)
    previous = Thread.current[PURPOSE_KEY]
    Thread.current[PURPOSE_KEY] = purpose
    yield
  ensure
    Thread.current[PURPOSE_KEY] = previous
  end

  # A reader's access, from PassportAccess. +entry+ holds the event and the
  # fields of AccessEvent; :reads_from is where this access's reads at the
  # custodian begin.
  def access(entry)
    within { current.accesses << entry.merge(at: entry[:at] || now) }
  end

  def reads_so_far = current ? current.pod_reads.size : 0

  # A read this service made at a custodian under its read grant
  # (PodStorage::ProtectedReader). +status+ is the custodian's HTTP status, nil
  # when no answer came.
  def pod_read(dpp_id:, base_url:, path:, status:)
    read = { at: now, dpp_id: dpp_id, custodian: base_url, pod_path: path,
             pod_object_id: path[%r{\A/object/([^/?]+)}, 1], status: status,
             purpose: Thread.current[PURPOSE_KEY] }
    within { current.pod_reads << read }
  end

  # An access grant was registered or revoked (AccessGrant). Written at once,
  # inside the caller's transaction.
  def grant_event(event, grant, by: nil, reason: nil)
    details = { "grant" => grant.summary.slice("jti", "sub", "roles", "scope", "dpps", "purpose"),
                "issuer" => grant.issuer_did }
    details["revokedBy"] = by if by
    details["revocationReason"] = reason if reason
    create_entry({ event: event, at: now, request_id: current&.request_id, operation: current&.operation,
                   reason: reason, details: details },
                 [["issuer", grant.issuer_did]])
  end

  # Entries visible to +did+ (nil: every entry, for the operator), newest
  # first. +after+ is the id of the last entry of the previous page.
  def entries(did: nil, dpp_id: nil, event: nil, since: nil, until_time: nil, after: nil, limit: DEFAULT_PAGE)
    scope = AccessEvent.all
    scope = scope.where(id: AccessEventParty.where(did: did).select(:access_event_id)) if did
    scope = scope.where(dpp_id: dpp_id) if dpp_id.present?
    scope = scope.where(event: event) if event.present?
    scope = scope.where(occurred_at: since..) if since
    scope = scope.where(occurred_at: ..until_time) if until_time
    scope = scope.where(id: ...after.to_i) if after.present?
    scope = scope.order(id: :desc)
    limit ? scope.limit(limit.to_i) : scope
  end

  # Removes entries older than the retention period. The one way entries
  # leave; in PostgreSQL only this transaction may delete them.
  def prune!(now: Time.now.utc, days: RETENTION_DAYS)
    cutoff = now - days.days
    AccessEvent.transaction do
      connection = AccessEvent.connection
      connection.execute("SET LOCAL dpp.access_log_prune = 'on'") if connection.adapter_name.downcase.include?("postg")
      old = AccessEvent.where(occurred_at: ...cutoff)
      AccessEventParty.where(access_event_id: old.select(:id)).delete_all
      old.delete_all
    end
  end

  def now = Time.now.utc

  # -- writing ---------------------------------------------------------------

  def write(context, status)
    reads = context.pod_reads.each_with_index.map { |read, index| read.merge(index: index) }
    claim!(context.accesses, reads)
    owners = {}

    rows = context.accesses.map { |entry| [entry[:at], :access, entry] } +
           reads.reject { |read| read[:claimed] }.map { |read| [read[:at], :read, read] }
    return if rows.empty?

    AccessEvent.transaction do
      rows.sort_by(&:first).each do |_, kind, row|
        if kind == :access
          write_access(row, context, status)
        else
          write_service_read(row, reads, context, owners)
        end
      end
    end
  end

  # The read at the custodian that delivered the controlled part to a reader
  # belongs to that reader's entry: the last read of content for the passport
  # after the access began.
  def claim!(accesses, reads)
    accesses.each do |entry|
      next if entry[:event] == "refused"

      read = reads.drop(entry[:reads_from].to_i)
                  .select { |r| !r[:claimed] && r[:dpp_id] == entry[:dpp_id] && content_read?(r) }.last
      next unless read

      read[:claimed] = true
      entry.merge!(custodian: read[:custodian], pod_object_id: read[:pod_object_id], pod_path: read[:pod_path])
    end
  end

  def content_read?(read) = read[:pod_path].to_s.match?(CONTENT_READ)

  def write_access(entry, context, status)
    parties = [["owner", entry[:owner_did]], ["reader", entry[:reader_did]]] +
              Array(entry[:grants]).map { |grant| ["issuer", grant["iss"]] }
    create_entry(entry.slice(:event, :at, :dpp_id, :owner_did, :reader_did, :roles, :basis, :grants,
                             :version_date, :reason, :custodian, :pod_object_id, :pod_path,
                             :controlled_digest, :details)
                      .merge(request_id: context.request_id, operation: context.operation, status: status),
                 parties)
  end

  def write_service_read(read, reads, context, owners)
    owner = owners.fetch(read[:dpp_id]) { owners[read[:dpp_id]] = owner_of(read[:dpp_id]) }
    create_entry({ event: "serviceRead", at: read[:at], dpp_id: read[:dpp_id], owner_did: owner,
                   reason: read[:purpose] || service_reason(read, reads), custodian: read[:custodian],
                   pod_object_id: read[:pod_object_id], pod_path: read[:pod_path], status: read[:status],
                   request_id: context.request_id, operation: context.operation },
                 [["owner", owner]])
  end

  def service_reason(read, reads)
    path = read[:pod_path].to_s
    return "lookup" if path.match?(LOOKUP)
    return "version" if path.match?(VERSIONS)
    return "internal" unless content_read?(read)

    later = reads.drop(read[:index] + 1).any? { |r| r[:dpp_id] == read[:dpp_id] && content_read?(r) }
    return "internal" unless later

    path.start_with?("/dpp/v1/controlled/dppsByIdAndDate/") ? "version" : "retry"
  end

  def owner_of(dpp_id)
    return nil if dpp_id.blank?

    Dpp.where(dpp_id: dpp_id).pick(:owner_did) || DppVersion.where(dpp_id: dpp_id).order(:archived_at).pick(:owner_did)
  end

  def create_entry(fields, parties)
    record = AccessEvent.create!(
      occurred_at: fields[:at], event: fields[:event], dpp_id: fields[:dpp_id], owner_did: fields[:owner_did],
      reader_did: fields[:reader_did], roles: fields[:roles], basis: fields[:basis], grants: fields[:grants],
      operation: fields[:operation], version_date: fields[:version_date], status: fields[:status],
      reason: fields[:reason], custodian: fields[:custodian], pod_object_id: fields[:pod_object_id],
      pod_path: fields[:pod_path], controlled_digest: fields[:controlled_digest],
      request_id: fields[:request_id], details: fields[:details]
    )
    parties.select { |_, did| did.present? }.uniq.each do |relation, did|
      AccessEventParty.create!(access_event: record, did: did, relation: relation)
    end
    record
  end

  private_class_method :write, :claim!, :content_read?, :write_access, :write_service_read, :service_reason,
                       :owner_of, :create_entry
end
