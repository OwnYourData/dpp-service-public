# frozen_string_literal: true

require "cgi"
require "uri"

# The texts of the newsletter mails (docs/Newsletter.md), plain text, in the
# language of the subscription. Every mail names the sender with its address;
# every notification carries the link to unsubscribe.
module NewsletterMail
  SENDER = <<~TEXT.strip
    OwnYourData.eu – Verein zur Förderung der selbstständigen Nutzung von Daten
    Michael Scherz-Straße 14, 2540 Bad Vöslau, Austria
  TEXT

  CONFIRMATION = {
    "en" => {
      subject: "Please confirm: notifications about new Delegated Acts",
      body: <<~TEXT
        Hello,

        someone – hopefully you – asked OwnYourData to send notifications to this address when new Delegated Acts for Digital Product Passports are published.

        To confirm, open this link within 7 days and press “Confirm”:
        %<link>s

        If you did not ask for this, simply ignore this email. The request is deleted after 7 days.

        We store only your email address, your language and when you subscribed and confirmed. Privacy policy: %<privacy>s
      TEXT
    },
    "de" => {
      subject: "Bitte bestätigen: Benachrichtigung über neue delegierte Rechtsakte",
      body: <<~TEXT
        Guten Tag,

        jemand – hoffentlich Sie – hat OwnYourData gebeten, an diese Adresse eine Nachricht zu senden, wenn neue delegierte Rechtsakte zum Digitalen Produktpass veröffentlicht werden.

        Zum Bestätigen öffnen Sie bitte innerhalb von 7 Tagen diesen Link und drücken „Confirm“:
        %<link>s

        Wenn Sie das nicht angefordert haben, ignorieren Sie diese E-Mail einfach. Die Anfrage wird nach 7 Tagen gelöscht.

        Wir speichern nur Ihre E-Mail-Adresse, Ihre Sprache und wann Sie sich angemeldet und bestätigt haben. Datenschutzerklärung: %<privacy>s
      TEXT
    }
  }.freeze

  FOOTER = {
    "en" => "You receive this email because you subscribed to notifications about new Delegated Acts on %<site>s.\nUnsubscribe: %<link>s",
    "de" => "Sie erhalten diese E-Mail, weil Sie Benachrichtigungen über neue delegierte Rechtsakte auf %<site>s abonniert haben.\nAbmelden: %<link>s"
  }.freeze

  module_function

  def base_url(request = nil)
    (request&.base_url || ENV["DPP_SERVICE_ENDPOINT_BASE"].to_s).chomp("/")
  end

  def confirmation(subscription, base:)
    text = CONFIRMATION.fetch(subscription.locale)
    link = "#{base}/newsletter/confirm?token=#{CGI.escape(subscription.confirmation_token)}"
    { subject: text[:subject],
      body: "#{format(text[:body], link: link, privacy: "#{base}/privacy#newsletter")}\n#{SENDER}\n" }
  end

  # Subject and text of a notification from the text the rake task reads:
  # the first line is the subject (a leading "# " is dropped), the rest the
  # text.
  def split_issue(input)
    lines = input.to_s.sub(/\A\uFEFF/, "").lines
    subject = lines.shift.to_s.sub(/\A#\s*/, "").strip
    [subject, lines.join.strip]
  end

  # A notification with the link to unsubscribe in the footer and in the
  # headers for unsubscribing with one click (RFC 2369, RFC 8058): the mail
  # program sends a POST to the same address, which unsubscribes at once.
  def notification(subscription, subject:, text:, base:)
    link = "#{base}/newsletter/unsubscribe?token=#{CGI.escape(subscription.unsubscribe_token)}"
    footer = format(FOOTER.fetch(subscription.locale), site: URI.parse(base).host, link: link)
    { subject: subject, body: "#{text.strip}\n\n-- \n#{footer}\n\n#{SENDER}\n",
      headers: { "List-Unsubscribe" => "<#{link}>", "List-Unsubscribe-Post" => "List-Unsubscribe=One-Click" } }
  end
end
