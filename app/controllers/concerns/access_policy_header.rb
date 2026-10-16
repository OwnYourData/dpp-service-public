# frozen_string_literal: true

# The X-DPP-Access-Policy header (docs/AccessClasses.md).
#
# **On a request** (CreateDPP, UpdateDPP) it names, by its id, an access policy
# the economic operator has registered with PUT /dpp/v1/access-policies. The
# policy is attached to the passport; on UpdateDPP it replaces the one in
# place. A policy cannot be removed, so the header cannot be empty. Only the
# id travels: a whole policy for a product type with many attributes does not
# fit into one request header.
#
# **On a response** to a write of the owner on a passport with a policy it says
# which policy the passport is classified by and how well the policy fits the
# passport as it now stands, as an RFC 8941 item:
#
#   X-DPP-Access-Policy: "https://example.org/policies/lamp/1";unclassified=2;unused-rules=1
#
#   unclassified   attributes no rule reaches; they take the policy's default
#   unused-rules   rules that reach no attribute of the passport
#
# Counts only, so the header stays small whatever the size of the passport. The
# attributes and rules themselves are listed by
# GET /dpp/v1/dpps/{id}/access-policy. Read paths never carry the header.
module AccessPolicyHeader
  extend ActiveSupport::Concern

  ACCESS_POLICY_HEADER = "X-DPP-Access-Policy"

  # The registered policy the request header names, or nil without the header.
  # Raises AccessPolicy::InvalidError (-> 400) for an empty header and for an
  # id the presenting operator has not registered -- whether nobody has, or
  # another operator has, is not told apart.
  def access_policy_param
    raw = request.headers[ACCESS_POLICY_HEADER]
    return nil if raw.nil?

    id = raw.strip
    if id.empty?
      raise AccessPolicy::InvalidError,
            "#{ACCESS_POLICY_HEADER} has to name a registered access policy; a policy cannot be removed"
    end

    RegisteredAccessPolicy.lookup(access_policy_owner, id) ||
      raise(AccessPolicy::InvalidError,
            "#{ACCESS_POLICY_HEADER}: no access policy #{id} is registered for this economic operator")
  end

  # Whom a registered policy belongs to: the verified DID, or nobody when
  # tokens are not verified (TokenAuthenticatable).
  def access_policy_owner
    DidTokenVerifier.enabled? ? actor_did : nil
  end

  # For the fine-granular write paths, which leave the policy as it is.
  def refuse_access_policy_header!
    return unless request.headers.key?(ACCESS_POLICY_HEADER)

    render_result("ClientErrorBadRequest",
                  text: "#{ACCESS_POLICY_HEADER} is taken by CreateDPP and UpdateDPP only")
  end

  # After a write: the warnings for the passport as it now stands.
  def report_access_policy(dpp)
    record = dpp.access_policy_record
    return if record.nil?

    classification = record.policy.classify(dpp.to_document)
    response.set_header(ACCESS_POLICY_HEADER,
                        "#{sf_string(record.policy_id)};unclassified=#{classification.unclassified.size}" \
                        ";unused-rules=#{classification.unused_rules.size}")
  end

  private

  # RFC 8941 3.3.3. The id is printable ASCII (AccessPolicy), so escaping the
  # two special characters is all there is to do.
  def sf_string(value)
    "\"#{value.gsub(/[\\"]/) { |c| "\\#{c}" }}\""
  end
end
