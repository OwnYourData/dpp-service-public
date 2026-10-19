# frozen_string_literal: true

# Who reads, on the read paths (PassportAccess, docs/AccessClasses.md §8).
#
# Reading needs no token: without one a reader gets the public part. A reader
# with access rights presents the same self-issued bearer token as a writer
# (DidTokenVerifier): signed with the document key of its DID, for this
# service, short-lived. A token that is presented but does not hold is refused
# with 401 rather than read past -- a reader who meant to read with access
# rights would otherwise take a missing attribute for an absent one.
#
# Only verified tokens count. While tokens are not verified (DPP_AUTH_MODE
# other than "did") every reader gets the public part.
#
# The answer says in headers, never in the passport, which access classes were
# applied (X-DPP-Access-Roles) and whether access rights reached further than
# what could be read (X-DPP-Controlled-Part: unavailable, as an RFC 8941 item
# with the reason as parameter where there is one, e.g.
# "unavailable;reason=readerNotEntered"). An answer with access rights is for
# the one reader only and is not stored by any cache; every answer varies with
# Authorization.
module ReaderAccess
  extend ActiveSupport::Concern

  ROLES_HEADER      = "X-DPP-Access-Roles"
  CONTROLLED_HEADER = "X-DPP-Controlled-Part"

  def authenticate_reader!
    response.set_header("Vary", "Authorization")
    return if request.authorization.blank? || !DidTokenVerifier.enabled?
    return if current_actor.present?

    render_result("ClientNotAuthorized",
                  text: "Invalid bearer token; without a token the public part of a passport is returned")
  end

  # The verified DID of the reader, or nil.
  def reader_did
    DidTokenVerifier.enabled? ? actor_did : nil
  end

  def report_access(result)
    response.set_header(ROLES_HEADER, result.classes.join(", ")) if result.classes.any?
    response.set_header("Cache-Control", "private, no-store") if result.classes.any? || result.controlled
    return unless result.controlled

    response.set_header(CONTROLLED_HEADER,
                        result.reason ? "#{result.controlled};reason=#{result.reason}" : result.controlled)
  end

  # The text of a 404 on a fine-granular read path: an element that is not in
  # what could be read may be in the controlled part that could not.
  def missing_text(what, result)
    return "#{what} not found" unless result.controlled

    "#{what} not found in the public part; the controlled part of this passport is unavailable"
  end
end
