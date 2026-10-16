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
# what could be read (X-DPP-Controlled-Part: unavailable). An answer with
# access rights is for the one reader only and is not stored by any cache; every
# answer varies with Authorization.
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
    if result.classes.any?
      response.set_header(ROLES_HEADER, result.classes.join(", "))
      response.set_header("Cache-Control", "private, no-store")
    end
    response.set_header(CONTROLLED_HEADER, result.controlled) if result.controlled
  end
end
