# frozen_string_literal: true

# Sign-up, confirmation and unsubscribing for the notifications about new
# Delegated Acts (NewsletterSubscription, docs/Newsletter.md).
#
#   POST /newsletter              subscribe (email, locale); always answers
#                                 "check your inbox", whether or not the
#                                 address is known
#   GET  /newsletter/confirm      page with a button; POST confirms
#   GET  /newsletter/unsubscribe  page with a button; POST unsubscribes
#
# Confirming and unsubscribing need a POST, so that mail scanners that open
# links do not confirm or unsubscribe on their own. Without mail configuration
# (GraphMail.configured?) every path answers 404.
class NewsletterController < ActionController::Base
  layout false

  # The pages carry no session; the double opt-in is what protects an address
  # against being subscribed by someone else.
  skip_forgery_protection

  SIGNUPS_PER_HOUR = 5

  before_action :require_configuration

  def create
    return render_page(:check_inbox) if params[:website].present?
    return render_page(:too_many, status: :too_many_requests) if too_many_signups?

    NewsletterSubscription.prune_unconfirmed!
    subscription = NewsletterSubscription.find_or_initialize_by(email: NewsletterSubscription.normalize_value_for(:email, params[:email].to_s))
    return render_page(:check_inbox) if subscription.persisted? && (subscription.confirmed? || !subscription.resend_due?)

    subscription.locale = NewsletterSubscription::LOCALES.include?(params[:locale]) ? params[:locale] : "en"
    subscription.requested_at = Time.current
    return render_page(:invalid, status: :unprocessable_content) unless subscription.valid?

    subscription.save!
    mail = NewsletterMail.confirmation(subscription, base: NewsletterMail.base_url(request))
    GraphMail.deliver(to: subscription.email, **mail)
    render_page(:check_inbox)
  rescue GraphMail::Error => e
    Rails.logger.error("[newsletter] the confirmation mail could not be sent: #{e.message}")
    subscription.destroy if subscription&.persisted? && !subscription.confirmed?
    render_page(:mail_failed, status: :service_unavailable)
  end

  def confirm_form
    subscription = NewsletterSubscription.find_for_confirmation(params[:token])
    return render_page(:link_invalid, status: :not_found) unless subscription

    render_page(:confirm_form, token: params[:token])
  end

  def confirm
    subscription = NewsletterSubscription.find_for_confirmation(params[:token])
    return render_page(:link_invalid, status: :not_found) unless subscription

    newly = !subscription.confirmed?
    subscription.confirm!
    render_page(:confirmed, conversion: newly)
  end

  def unsubscribe_form
    subscription = NewsletterSubscription.find_for_unsubscribe(params[:token])
    return render_page(:unsubscribed) unless subscription

    render_page(:unsubscribe_form, token: params[:token])
  end

  def unsubscribe
    NewsletterSubscription.find_for_unsubscribe(params[:token])&.destroy
    render_page(:unsubscribed)
  end

  private

  def require_configuration
    head :not_found unless GraphMail.configured?
  end

  def too_many_signups?
    RateCounter.hit!("#{request.remote_ip}:newsletter", within: 3600) > SIGNUPS_PER_HOUR
  end

  def render_page(state, status: :ok, token: nil, conversion: false)
    @state = state
    @token = token
    @conversion = conversion
    render :page, formats: :html, status: status
  end
end
