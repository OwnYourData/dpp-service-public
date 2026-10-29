# frozen_string_literal: true

# The related resources of a passport that do not say what they are.
#
# EN 18223:2026 Table 5 gives a RelatedResource its media type next to its
# address. A resource without one is still reachable, so a write that leaves
# it out is not refused; but a reader cannot tell what the address will
# return, and a viewer cannot offer it sensibly. The write paths therefore
# report such resources (WriteWarnings).
#
# Plain Ruby: walks the full representation (EN 18223:2026 Annex A), the only
# one that carries the type. A document stored compressed has no
# RelatedResource objects to look at and yields nothing.
module RelatedResourceCheck
  NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  module_function

  # The elementIdPaths (RFC 9535 singular queries, as ElementIdPath reads
  # them) of every RelatedResource without a non-empty contentType, in
  # document order.
  def missing_content_type(document)
    return [] unless document.is_a?(Hash)

    walk(Array(document["elements"]), "$", [])
  end

  def walk(elements, prefix, found)
    elements.each_with_index do |element, index|
      next unless element.is_a?(Hash)

      path = prefix + segment(element["elementId"], index)
      if element["objectType"] == "RelatedResource"
        found << path if element["contentType"].to_s.strip.empty?
      elsif element["elements"].is_a?(Array)
        walk(element["elements"], path, found)
      end
    end
    found
  end

  def segment(element_id, index)
    id = element_id.to_s
    return "[#{index}]" if id.empty?
    return ".#{id}" if id.match?(NAME)

    "[#{JSON.generate(id)}]"
  end
end
