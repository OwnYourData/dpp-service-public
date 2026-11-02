# frozen_string_literal: true

# Notifications about new Delegated Acts (docs/Newsletter.md). Run in the
# cluster, for example:
#
#   kubectl -n dpp exec -i deploy/dpp-service -- bin/rails newsletter:stats
#   kubectl -n dpp exec -i deploy/dpp-service -- bin/rails newsletter:send LOCALE=en < issue-en.md
#   kubectl -n dpp exec -i deploy/dpp-service -- bin/rails newsletter:send LOCALE=en SEND=1 < issue-en.md
#
# The text comes on standard input: the first line is the subject (a leading
# "# " is dropped), the rest is the body, sent as plain text. Without SEND=1
# the task only says how many subscribers would receive what. No address is
# ever printed.
namespace :newsletter do
  desc "Count confirmed and unconfirmed subscriptions by language"
  task stats: :environment do
    NewsletterSubscription::LOCALES.each do |locale|
      scope = NewsletterSubscription.where(locale: locale)
      puts "#{locale}: #{scope.confirmed.count} confirmed, #{scope.where(confirmed_at: nil).count} awaiting confirmation"
    end
  end

  desc "Delete subscriptions not confirmed within the confirmation period"
  task prune: :environment do
    puts "#{NewsletterSubscription.prune_unconfirmed!} unconfirmed subscriptions deleted"
  end

  # Exchange Online accepts 30 messages a minute from one mailbox.
  SEND_INTERVAL = 2.1

  desc "Send a notification (subject and text on standard input) to the confirmed subscribers of LOCALE; SEND=1 sends"
  task send: :environment do
    locale = ENV.fetch("LOCALE", "")
    abort "LOCALE has to be one of #{NewsletterSubscription::LOCALES.join(', ')}" unless NewsletterSubscription::LOCALES.include?(locale)
    abort "mail is not configured (docs/Newsletter.md)" unless GraphMail.configured?

    subject, text = NewsletterMail.split_issue($stdin.read)
    abort "the first line (the subject) is empty" if subject.blank?
    abort "the text after the subject is empty" if text.blank?

    recipients = NewsletterSubscription.confirmed.where(locale: locale)
    base = NewsletterMail.base_url
    puts "Subject: #{subject}"
    puts "Recipients (#{locale}, confirmed): #{recipients.count}"
    unless ENV["SEND"] == "1"
      sample = Struct.new(:locale, :unsubscribe_token).new(locale, "…")
      puts "\n#{NewsletterMail.notification(sample, subject: subject, text: text, base: base)[:body]}"
      puts "Dry run: nothing sent. Add SEND=1 to send."
      next
    end

    sent = failed = 0
    recipients.find_each do |subscription|
      GraphMail.deliver(to: subscription.email, **NewsletterMail.notification(subscription, subject: subject, text: text, base: base))
      sent += 1
    rescue GraphMail::Error => e
      failed += 1
      warn "subscription #{subscription.id}: #{e.message}"
    ensure
      sleep SEND_INTERVAL unless Rails.env.test?
    end
    puts "#{sent} sent, #{failed} failed"
  end
end

