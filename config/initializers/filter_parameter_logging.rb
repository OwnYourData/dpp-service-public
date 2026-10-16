# frozen_string_literal: true

# Kept out of the log. Matched as parts of a parameter name, so :_key covers
# doc_key and rev_key, :token covers every kind of token, and :delegation the
# signed mandate should it ever arrive as a parameter rather than in the
# X-DPP-Storage header.
Rails.application.config.filter_parameters += %i[
  passw secret token _key crypt salt certificate otp ssn
  delegation authorization rev_log
]
