# frozen_string_literal: true

# RFC 7396 — JSON Merge Patch. Referenced by prEN 18222 §4.7 (UpdateDPP) and
# §6.4/§6.5 for partial updates of DPPs and data elements.
module JsonMergePatch
  module_function

  # Applies +patch+ to +target+ and returns the merged result.
  # A null value in the patch removes the corresponding key (RFC 7396 §2).
  def apply(target, patch)
    return patch unless patch.is_a?(Hash)

    result = target.is_a?(Hash) ? target.dup : {}
    patch.each do |key, value|
      if value.nil?
        result.delete(key)
      else
        result[key] = apply(result[key], value)
      end
    end
    result
  end
end
