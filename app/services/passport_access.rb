# frozen_string_literal: true

# The one place every read of a passport passes through (docs/AccessClasses.md
# §8): ReadDPPById, ReadDPPByProductId, ReadDPPVersionByIdAndDate,
# ReadDataElement and the collection path all take their document from here,
# and nothing else on a read path touches the controlled part.
#
# A reader without access rights gets what is published: the public card of a
# pod-backed passport, the public part of a local one. A reader with access
# rights -- the owner of the passport, or a reader DID holding an access grant
# for it (AccessGrant) -- gets the public part and those attributes of the
# controlled part whose class it may read (AccessPolicy#visible_for). The
# controlled part is read under this service's own read grant, never under the
# write delegation, and it is checked against the digest the public part names
# (ControlledData) before anything of it is handed out.
#
# The answer is the passport of EN 18223:2026 with more data elements, nothing
# else: the header is the public one, ControlledData stays as the public part
# has it, the salt never leaves. Which classes were applied is said in a
# response header (ReaderAccess), not in the passport.
#
# Archived versions are filtered by the passport's access policy as it is
# today, also for readers without access rights: an attribute that is
# controlled today is not handed out from an earlier version in which it was
# public.
#
# Every read with access rights is logged, and so is every reader with a
# verified token who has none for a passport with an access policy
# (AccessLog). A reader without a token reads what is public and is not
# logged.
class PassportAccess
  # The controlled part does not match the digest the public part names.
  class IntegrityError < PodStorage::Error; end

  # +classes+: the access classes beyond public that were applied (notations);
  # +controlled+: "unavailable" when access rights reached further than what
  # could be read.
  Result = Struct.new(:document, :classes, :controlled, keyword_init: true)

  UNAVAILABLE = "unavailable"

  # How many versions of a controlled card are tried when the one at the
  # requested time does not match the public version.
  VERSION_TRIES = 4

  # What a reader holds for a passport: the classes beyond public, on what
  # basis ("owner" or "grant"), and the grants as { "iss", "jti" }.
  Access = Struct.new(:roles, :basis, :grants)
  NO_ACCESS = Access.new([], nil, []).freeze

  def self.current(dpp, reader:) = new(reader).current(dpp)

  def self.version_at(dpp_id, time, reader:) = new(reader).version_at(dpp_id, time)

  def initialize(reader_did)
    @reader = DidTokenVerifier.enabled? ? reader_did.presence : nil
  end

  # The access classes beyond public the reader holds for a passport: all of
  # them for its owner, those of its access grants otherwise.
  def roles_for(dpp_id, owner_did) = access_for(dpp_id, owner_did).roles

  def access_for(dpp_id, owner_did)
    return NO_ACCESS if @reader.nil?
    if owner_did.present? && @reader == owner_did
      return Access.new(AccessClass.notations - [AccessClass.public_class.notation], "owner", [])
    end

    grants = AccessGrant.applicable(@reader, dpp_id: dpp_id, owner_did: owner_did)
    return NO_ACCESS if grants.empty?

    Access.new(grants.flat_map(&:effective_roles).uniq, "grant",
               grants.map { |grant| { "iss" => grant.issuer_did, "jti" => grant.jti } })
  end

  def current(dpp)
    AccessLog.within do
      published = dpp.published_document
      policy = dpp.access_policy
      return Result.new(document: published, classes: []) if policy.nil?

      access = access_for(dpp.dpp_id, dpp.owner_did)
      return refused(dpp.dpp_id, dpp.owner_did, published) if access.roles.empty?

      logged(dpp.dpp_id, dpp.owner_did, access) do |entry|
        published, full = current_parts(dpp, published)
        entry[:controlled_digest] = PassportSplit.named_digest(published)
        result(dpp.dpp_id, policy, access.roles, published, full)
      end
    end
  end

  def version_at(dpp_id, time)
    @version_date = time
    AccessLog.within do
      pod_dpp = Dpp.find_by(dpp_id: dpp_id, storage_backend: "pod")
      next pod_version(pod_dpp, time) if pod_dpp

      version = DppVersion.where(dpp_id: dpp_id).where(archived_at: time..).order(:archived_at).first
      next local_version(version) if version

      current(Dpp.active.find(dpp_id))
    end
  end

  private

  # [published, whole passport] as they stand now; the controlled part is
  # read and checked against the digest, once more if they do not match (a
  # write may be under way), and refused if they still do not.
  def current_parts(dpp, published)
    return [published, dpp.to_document] if !dpp.pod? && dpp.controlled_content.blank?

    named = PassportSplit.named_digest(published)
    return [published, PassportSplit.strip(published)] if named.nil?

    controlled = dpp.controlled_part
    unless matches?(controlled, named)
      dpp.forget_read_content!
      published = dpp.published_document
      named = PassportSplit.named_digest(published)
      controlled = dpp.controlled_part
      refuse!(dpp.dpp_id) unless matches?(controlled, named)
    end
    [published, PassportSplit.merge(published, controlled)]
  end

  # A version of a pod-backed passport: the public card as it stood then and,
  # for a reader with access rights, the version of the controlled card it
  # names.
  def pod_version(dpp, time)
    published = dpp.pod_reader.version_at(dpp.dpp_id, time)
    raise ActiveRecord::RecordNotFound, "no version of #{dpp.dpp_id} at #{time.iso8601}" if published.nil?

    policy = dpp.access_policy
    return Result.new(document: published, classes: []) if policy.nil?

    access = access_for(dpp.dpp_id, dpp.owner_did)
    if access.roles.empty?
      public_view = result(dpp.dpp_id, policy, [], published, PassportSplit.strip(published))
      return refused(dpp.dpp_id, dpp.owner_did, public_view.document)
    end

    logged(dpp.dpp_id, dpp.owner_did, access) do |entry|
      named = PassportSplit.named_digest(published)
      controlled = named ? archived_controlled(dpp, time, named) : nil
      full = controlled ? PassportSplit.merge(published, controlled) : PassportSplit.strip(published)
      entry[:controlled_digest] = named if controlled

      answer = result(dpp.dpp_id, policy, access.roles, published, full)
      answer.controlled = UNAVAILABLE if named && controlled.nil?
      answer
    end
  end

  # The version of the controlled card whose digest the public version names.
  # The controlled card is written before the public one, so the version at
  # the same time can be one ahead; then the versions next to it are tried.
  # nil when the custodian serves no versions of controlled cards.
  def archived_controlled(dpp, time, named)
    reader = dpp.protected_reader
    candidate = reader.controlled_at(dpp.dpp_id, time)
    return candidate if matches?(candidate, named)

    versions = reader.controlled_versions(dpp.dpp_id)
    return nil if versions.nil? && candidate.nil?

    Array(versions).map { |v| Time.iso8601(v["timestamp"].to_s) }
                   .sort_by { |at| (at - time).abs }.first(VERSION_TRIES)
                   .each do |at|
      # Timestamps come in whole seconds; the version is the last one before
      # the end of that second.
      document = reader.controlled_at(dpp.dpp_id, at + 0.999)
      return document if matches?(document, named)
    end
    refuse!(dpp.dpp_id)
  rescue ArgumentError
    refuse!(dpp.dpp_id)
  end

  # An archived version of a local passport. It holds the whole passport; the
  # policy is the passport's today, or the last one it had if it is deleted.
  def local_version(version)
    dpp = Dpp.find_by(dpp_id: version.dpp_id)
    policy = dpp ? dpp.access_policy : last_policy(version.dpp_id)
    return Result.new(document: version.content, classes: []) if policy.nil?

    owner = dpp ? dpp.owner_did : version.owner_did
    access = access_for(version.dpp_id, owner)
    if access.roles.empty?
      public_view = result(version.dpp_id, policy, [], version.content, version.content)
      return refused(version.dpp_id, owner, public_view.document)
    end

    logged(version.dpp_id, owner, access) do
      result(version.dpp_id, policy, access.roles, version.content, version.content)
    end
  end

  # A reader with a verified token and no valid access right reads a passport
  # that has an access policy: the public part, and an entry in the access
  # log saying why nothing more (AccessGrant.refusal_for). A reader without a
  # token reads what is public, and is not logged.
  def refused(dpp_id, owner_did, document)
    if @reader
      reason, grant = AccessGrant.refusal_for(@reader, dpp_id: dpp_id, owner_did: owner_did)
      AccessLog.access(event: "refused", dpp_id: dpp_id, owner_did: owner_did, reader_did: @reader,
                       version_date: @version_date, reason: reason, grants: grant ? [grant] : nil)
    end
    Result.new(document: document, classes: [])
  end

  # Runs a read with access rights and logs it: as read, or as
  # integrityError when the controlled part did not match its digest. The
  # entry is written with the request (AccessLog), and the answer is not sent
  # without it (AccessLogging).
  def logged(dpp_id, owner_did, access)
    entry = { event: "read", dpp_id: dpp_id, owner_did: owner_did, reader_did: @reader, roles: access.roles,
              basis: access.basis, grants: access.grants.presence, version_date: @version_date,
              reads_from: AccessLog.reads_so_far, at: AccessLog.now }
    answer = yield entry
    entry[:roles] = answer.classes
    answer
  rescue IntegrityError
    entry[:event] = "integrityError"
    raise
  ensure
    AccessLog.access(entry) if entry
  end

  def last_policy(dpp_id)
    id = DppVersion.where(dpp_id: dpp_id).where.not(access_policy_id: nil)
                   .order(archived_at: :desc).pick(:access_policy_id)
    id && RegisteredAccessPolicy.find_by(id: id)&.policy
  end

  def result(dpp_id, policy, roles, published, full)
    document = policy.visible_for(roles, full)
    digest = Array(published["elements"]).find { |e| PassportSplit.service_element?(e) && e["elementId"] == PassportSplit::DIGEST_ELEMENT }
    document = document.merge("elements" => Array(document["elements"]) + [digest]) if digest

    classes = AccessClass.readable_with(roles).map(&:notation) - [AccessClass.public_class.notation]
    if classes.any?
      Rails.logger.info("[access] #{dpp_id} read by #{@reader} with #{classes.join(', ')}")
    end
    Result.new(document: document, classes: classes)
  end

  def matches?(controlled, named)
    controlled.is_a?(Hash) && named.present? && PassportSplit.digest(controlled) == named
  end

  def refuse!(dpp_id)
    Rails.logger.error("[access] the controlled part of #{dpp_id} does not match the digest its public part " \
                       "names; nothing of it was handed out")
    raise IntegrityError, "the controlled part of this passport does not match the digest its public part " \
                          "names (ControlledData); it is not handed out"
  end
end
