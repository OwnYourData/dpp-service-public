# frozen_string_literal: true

require "digest"

# An access policy (AccessPolicy) as an economic operator registered it with
# this service, once per product type. A passport refers to one at CreateDPP
# with the X-DPP-Access-Policy header and is classified by it from then on.
#
# Registered policies are immutable. Passports refer to them, and the
# classification of a passport has to stay traceable to the policy it was made
# under, so a new version of a product type's policy is registered under a new
# id. Registering the same id again is answered by what is already there:
# the same policy is accepted as it is, a different one is a conflict.
#
# "The same" means the same document up to the order of its members and of its
# rules: neither carries any meaning (one rule per path, the deepest one wins).
#
# Policies belong to the operator that registered them. Another operator using
# the same id has a policy of its own, and a passport can only refer to a
# policy of its own operator.
class RegisteredAccessPolicy < ApplicationRecord
  self.table_name = "access_policies"

  # The id travels in a request header and comes back in a response header.
  MAX_ID_LENGTH = 512

  class Conflict < StandardError; end

  validates :policy_id, :digest, presence: true

  # Registers +document+ for +owner_did+ (nil when tokens are not verified).
  # Returns [record, created]; raises AccessPolicy::InvalidError for a policy
  # that is not valid and Conflict when the id is taken by different content.
  def self.register!(owner_did, document)
    policy = AccessPolicy.parse(document)
    if policy.id.length > MAX_ID_LENGTH
      raise AccessPolicy::InvalidError, "access policy id is longer than #{MAX_ID_LENGTH} characters"
    end

    digest = digest_of(document)
    existing = lookup(owner_did, policy.id)
    return [same!(existing, digest), false] if existing

    [create!(owner_did: owner_did, policy_id: policy.id, document: document, digest: digest), true]
  rescue ActiveRecord::RecordNotUnique
    # A concurrent registration of the same id got there first.
    [same!(lookup(owner_did, policy.id), digest), false]
  end

  def self.lookup(owner_did, policy_id)
    find_by(owner_did: owner_did, policy_id: policy_id)
  end

  def self.digest_of(document)
    normalized = document.merge("rules" => Array(document["rules"]).sort_by { |rule| rule["path"].to_s })
    Digest::SHA256.hexdigest(canonical(normalized))
  end

  def self.canonical(value)
    case value
    when Hash  then "{#{value.keys.sort_by(&:to_s).map { |k| "#{k.to_s.to_json}:#{canonical(value[k])}" }.join(',')}}"
    when Array then "[#{value.map { |v| canonical(v) }.join(',')}]"
    else value.to_json
    end
  end

  def self.same!(record, digest)
    return record if record.digest == digest

    raise Conflict, "access policy #{record.policy_id} is registered with different content; " \
                    "a new version of a policy needs a new id"
  end
  private_class_method :same!, :canonical

  def policy
    @policy ||= AccessPolicy.parse(document)
  end
end
