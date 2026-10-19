# frozen_string_literal: true

# A request body that does not parse as its Content-Type says is logged by Rails
# in full, at level debug ("Error occurred while parsing request parameters.
# Contents: ..."). The filter for parameters cannot reach it: there are no
# parameters yet, only the raw body.
#
# Here that body can be a secret. An access grant is sent as the raw body of
# PUT /dpp/v1/access-grants, and a client that labels it application/json --
# an easy mistake, and the request still succeeds, because the controller reads
# the body itself -- would put the whole signed grant into the log. So the line
# says that parsing failed, how long the body was and what it claimed to be,
# and not what it said.
module QuietParseErrors
  private

  def log_parse_error_once
    @parse_error_logged ||= begin
      parse_logger = logger || ActiveSupport::Logger.new($stderr)
      parse_logger.debug("Error occurred while parsing request parameters " \
                         "(#{content_mime_type}, #{raw_post.to_s.bytesize} bytes; contents not logged).")
      true
    end
  end
end

ActionDispatch::Request.prepend(QuietParseErrors)
