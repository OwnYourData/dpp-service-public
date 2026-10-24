# frozen_string_literal: true

# The bearer tokens this service has accepted, by issuer and jti, until they
# expire (DidTokenVerifier): a token is accepted once, by whichever replica
# sees it first. Nothing of the token is kept beyond the two names and the
# expiry.
#
# Written with ON CONFLICT DO NOTHING rather than by catching the unique
# index: a failed insert would abort a surrounding PostgreSQL transaction.
class TokenUse < ApplicationRecord
  class Replayed < StandardError; end

  MAX_JTI     = 255
  PRUNE_EVERY = 200

  def self.record!(issuer:, jti:, expires_at:, now: Time.now.to_i)
    result = insert({ issuer: issuer, jti: jti, expires_at: expires_at },
                    unique_by: %i[issuer jti], returning: %w[id])
    prune!(now) if rand(PRUNE_EVERY).zero?
    raise Replayed, "jti #{jti} of #{issuer} was presented before" if result.rows.empty?

    true
  end

  def self.prune!(now = Time.now.to_i) = where(expires_at: ...now).delete_all
end
