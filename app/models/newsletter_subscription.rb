# frozen_string_literal: true

# A subscription to the notifications about new Delegated Acts
# (docs/Newsletter.md). Double opt-in: a subscription receives notifications
# only once its address has been confirmed through the link in the
# confirmation mail. Unconfirmed subscriptions are deleted after
# CONFIRMATION_PERIOD; unsubscribing deletes the row at once.
#
# The links carry signed ids (Rails signed_id, keyed with secret_key_base), so
# no token is stored: the confirmation link expires with CONFIRMATION_PERIOD,
# the unsubscribe link does not expire.
class NewsletterSubscription < ApplicationRecord
  LOCALES = %w[en de].freeze
  CONFIRMATION_PERIOD = 7.days
  # A new confirmation mail for the same address goes out at most this often,
  # so that the form cannot be used to flood someone's inbox.
  RESEND_AFTER = 10.minutes
  MAX_EMAIL_LENGTH = 254

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :email, presence: true, length: { maximum: MAX_EMAIL_LENGTH },
                    format: { with: /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/ }
  validates :locale, inclusion: { in: LOCALES }

  scope :confirmed, -> { where.not(confirmed_at: nil) }

  def self.prune_unconfirmed!(now: Time.current)
    where(confirmed_at: nil).where(requested_at: ...(now - CONFIRMATION_PERIOD)).delete_all
  end

  def self.find_for_confirmation(token)
    find_signed(token.to_s, purpose: :newsletter_confirm)
  end

  def self.find_for_unsubscribe(token)
    find_signed(token.to_s, purpose: :newsletter_unsubscribe)
  end

  def confirmed? = confirmed_at.present?

  def confirmation_token = signed_id(purpose: :newsletter_confirm, expires_in: CONFIRMATION_PERIOD)

  def unsubscribe_token = signed_id(purpose: :newsletter_unsubscribe)

  def confirm!(now: Time.current)
    update!(confirmed_at: now) unless confirmed?
  end

  def resend_due?(now: Time.current) = requested_at <= now - RESEND_AFTER
end
