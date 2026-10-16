# frozen_string_literal: true

require "digest"

# An access grant: the statement, signed by its issuer, that a reader DID may
# read the controlled part of passports in the access classes it names
# (docs/AccessClasses.md §7). The statement is checked by
# Delegation.verify_access_grant!; this class decides whether its issuer may
# grant what it grants, keeps it, and answers which classes a reader holds for
# a passport.
#
# Who may grant what:
#
#   legitimateInterest   the economic operator, for its own passports (the
#                        owner DID of the passport); an authority issuer
#   authority            only an issuer on the list of authority issuers
#                        (AuthorityIssuers)
#
# Which passports a grant covers: those named in +dpps+, or with scope
# "issuer" every passport of the issuer -- for an authority issuer every
# passport this service holds. A grant of an economic operator covers only
# passports it owns, whatever it names.
#
# A grant is registered by its issuer, once; the same grant again is answered
# by what is there, a different one under the same jti is a conflict. It is
# never deleted: revoking it sets +revoked_at+, so what was read under it stays
# traceable to it. A revoked grant stays revoked; registering it again brings
# it back as revoked. Registering and revoking are logged (AccessLog).
#
# Revoking: the issuer, over the API; the operator of this service, on order,
# with a reason, in the cluster (bin/rails dpp:access:revoke). The economic
# operator cannot revoke a grant it did not issue, an authority grant above
# all.
class AccessGrant < ApplicationRecord
  AUTHORITY = "authority"

  class Forbidden < StandardError; end
  class Conflict < StandardError; end

  validates :issuer_did, :jti, :subject_did, :scope, :token, :digest, presence: true

  scope :in_force, lambda { |now = Time.now.utc|
    skew = Delegation::CLOCK_SKEW.seconds
    where(revoked_at: nil).where(not_before: ..(now + skew)).where(expires_at: (now - skew)..)
  }

  # Registers +token+, presented by +presenter_did+ (nil when tokens are not
  # verified). Returns [record, created]. Raises Delegation::Invalid for a
  # grant that does not hold, Forbidden for one its issuer may not give and
  # Conflict for a different grant under the same jti.
  def self.register!(presenter_did, token)
    claims = Delegation.verify_access_grant!(token)
    issuer = claims["iss"]

    if DidTokenVerifier.enabled? && presenter_did != issuer
      raise Forbidden, "an access grant is registered by its issuer, #{issuer}"
    end
    check_issuer!(issuer, claims)

    digest = Digest::SHA256.hexdigest(token)
    existing = find_by(issuer_did: issuer, jti: claims["jti"])
    return [same!(existing, digest), false] if existing

    record = nil
    transaction do
      record = create!(issuer_did: issuer, jti: claims["jti"], subject_did: claims["sub"],
                       roles: claims["roles"].map { |role| AccessClass.resolve(role).notation }.uniq,
                       scope: claims.key?("scope") ? "issuer" : "dpps", dpp_ids: claims["dpps"]&.uniq,
                       purpose: claims["purpose"], not_before: Time.at(claims["nbf"]).utc,
                       expires_at: Time.at(claims["exp"]).utc, token: token, digest: digest)
      AccessLog.grant_event("grantRegistered", record)
    end
    [record, true]
  rescue ActiveRecord::RecordNotUnique
    [same!(find_by(issuer_did: issuer, jti: claims["jti"]), digest), false]
  end

  # The access classes +reader_did+ holds for the passport +dpp_id+ of
  # +owner_did+, from every grant in force. Empty without a grant.
  def self.roles_for(reader_did, dpp_id:, owner_did:, now: Time.now.utc)
    applicable(reader_did, dpp_id: dpp_id, owner_did: owner_did, now: now).flat_map(&:effective_roles).uniq
  end

  # The grants in force that give +reader_did+ a class for the passport.
  # Asked of the database on every read: a revoked grant counts no more from
  # the moment it is revoked.
  def self.applicable(reader_did, dpp_id:, owner_did:, now: Time.now.utc)
    return [] if reader_did.blank?

    in_force(now).where(subject_did: reader_did).order(:id)
                 .select { |grant| grant.covers?(dpp_id: dpp_id, owner_did: owner_did) && grant.effective_roles.any? }
  end

  # Why +reader_did+ holds nothing for the passport, for the access log:
  # [reason, { "iss", "jti" } of the grant concerned or nil]. A grant that
  # would cover the passport but is revoked, expired, not yet valid, or for
  # authority from an issuer no longer on the list, is named; otherwise
  # "noGrant".
  def self.refusal_for(reader_did, dpp_id:, owner_did:, now: Time.now.utc)
    covering = where(subject_did: reader_did).order(id: :desc)
                 .select { |grant| grant.covers_ignoring_list?(dpp_id: dpp_id, owner_did: owner_did) }
    skew = Delegation::CLOCK_SKEW.seconds
    { "revoked" => ->(g) { g.revoked? },
      "expired" => ->(g) { g.expires_at < now - skew },
      "notYetValid" => ->(g) { g.not_before > now + skew },
      "issuerNotListed" => ->(_) { true } }.each do |reason, test|
      grant = covering.find(&test)
      return [reason, { "iss" => grant.issuer_did, "jti" => grant.jti }] if grant
    end
    ["noGrant", nil]
  end

  def self.check_issuer!(issuer, claims)
    authority_issuer = AuthorityIssuers.include?(issuer)
    if claims["roles"].map { |role| AccessClass.resolve(role).notation }.include?(AUTHORITY) && !authority_issuer
      raise Forbidden, "#{issuer} is not on the list of issuers this service takes a grant for " \
                       "\"authority\" from"
    end
    return if authority_issuer || claims.key?("scope")

    named = claims["dpps"].uniq
    owned = Dpp.where(dpp_id: named, owner_did: issuer).pluck(:dpp_id)
    missing = named - owned
    return if missing.empty?

    raise Forbidden, "#{missing.size} of the passports this grant names are not passports of #{issuer} " \
                     "held by this service"
  end

  def self.same!(record, digest)
    return record if record.digest == digest

    raise Conflict, "a different access grant of #{record.issuer_did} is registered under jti #{record.jti}"
  end
  private_class_method :check_issuer!, :same!

  def authority_issuer? = AuthorityIssuers.include?(issuer_did)

  # The roles this grant gives today: "authority" only while its issuer is on
  # the list of authority issuers.
  def effective_roles
    Array(roles).reject { |role| role == AUTHORITY && !authority_issuer? }
  end

  def covers?(dpp_id:, owner_did:)
    return false unless authority_issuer? || (owner_did.present? && owner_did == issuer_did)

    scope == "issuer" || Array(dpp_ids).include?(dpp_id)
  end

  # Whether the grant would cover the passport if its issuer were still on the
  # list of authority issuers (for the reason of a refusal).
  def covers_ignoring_list?(dpp_id:, owner_did:)
    return false unless authority_issuer? || Array(roles).include?(AUTHORITY) ||
                        (owner_did.present? && owner_did == issuer_did)

    scope == "issuer" || Array(dpp_ids).include?(dpp_id)
  end

  def revoked? = revoked_at.present?

  # Revokes the grant, with effect from now. +by+ is the issuer's DID or
  # "operator"; the operator names a reason. Returns false if it was revoked
  # before, and changes nothing then.
  def revoke!(by:, reason: nil)
    revoked_now = false
    transaction do
      lock!
      unless revoked?
        update!(revoked_at: Time.now.utc, revoked_by: by, revocation_reason: reason.presence)
        AccessLog.grant_event("grantRevoked", self, by: by, reason: reason.presence)
        revoked_now = true
      end
    end
    revoked_now
  end

  # What the issuer gets back when it asks for its grants: everything it
  # signed, and whether the grant is revoked; not the signed statement itself.
  def summary
    { "jti" => jti, "sub" => subject_did, "roles" => roles, "scope" => scope, "dpps" => dpp_ids,
      "purpose" => purpose, "nbf" => not_before.to_i, "exp" => expires_at.to_i,
      "revoked" => revoked?, "revokedAt" => revoked_at&.to_i, "revokedBy" => revoked_by }.compact
  end
end
