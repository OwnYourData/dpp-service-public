# frozen_string_literal: true

# A line the operator puts at the top of the start page, from
# DPP_INSTANCE_NOTICE: for an instance that is not the public one, what it is
# for and how long it stays. Plain text, escaped when rendered. Without the
# variable, or with only blanks in it, the start page shows no notice.
module InstanceNotice
  VARIABLE = "DPP_INSTANCE_NOTICE"
  MAX_LENGTH = 300

  module_function

  def text
    value = ENV[VARIABLE].to_s.strip
    value.empty? ? nil : value[0, MAX_LENGTH]
  end
end
