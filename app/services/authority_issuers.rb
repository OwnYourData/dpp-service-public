# frozen_string_literal: true

# The issuers this service takes an access grant for the class "authority"
# from (AccessGrant). Whether a DID belongs to a market surveillance authority,
# a customs authority, a notified body or the Commission is not something the
# economic operator decides, nor something this service can tell from the DID
# itself; it takes the word of the issuers on this list.
#
# Configuration, from the environment like the reader DIDs:
#
#   DPP_AUTHORITY_ISSUERS   DIDs, comma-separated
#
# Without the variable no grant for "authority" is accepted. The list is
# published under /.well-known/dpp-service as "authorityIssuers".
module AuthorityIssuers
  ENV_NAME = "DPP_AUTHORITY_ISSUERS"

  module_function

  def all(env = ENV)
    env[ENV_NAME].to_s.split(",").map(&:strip).reject(&:empty?).uniq
  end

  def include?(did, env = ENV)
    !did.to_s.empty? && all(env).include?(did.to_s)
  end
end
