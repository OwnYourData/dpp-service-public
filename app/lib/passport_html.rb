# frozen_string_literal: true

require "erb"

# A passport as HTML, for a person who scanned its data carrier with a phone
# (EN 18216:2026 clause 5: JSON is the format, HTML is offered through content
# negotiation). CarrierController answers with this when the request prefers
# text/html; everything else gets the JSON.
#
# The page is built from the full representation (EN 18223:2026 Annex A),
# whatever representation the request named, because only the full form
# carries units and the type of a related resource. It shows exactly the
# document the same reader would get as JSON -- the public part, or more for
# a reader with access rights -- and nothing else.
#
# Self-contained: no script, no stylesheet or font from elsewhere, no form,
# no cookie. Every value is escaped, and only http and https addresses
# become links.
module PassportHtml
  HEADER = [
    ["uniqueProductIdentifier", "Product identifier"],
    ["digitalProductPassportId", "Passport identifier"],
    ["granularity", "Granularity"],
    ["economicOperatorId", "Economic operator"],
    ["facilityId", "Facility"],
    ["dppStatus", "Status"],
    ["dppSchemaVersion", "Data model"],
    ["lastUpdated", "Last updated"]
  ].freeze

  SECURITY_POLICY = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; " \
                    "form-action 'none'; frame-ancestors 'none'"

  STYLE = <<~CSS
    body{margin:0;font:16px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;color:#1d2433;background:#f6f7f9}
    main{max-width:46rem;margin:0 auto;padding:1.5rem 1rem 3rem}
    h1{font-size:1.5rem;margin:0 0 .25rem}h2{font-size:1.15rem;margin:2rem 0 .5rem}
    h3{font-size:1rem;margin:1.25rem 0 .25rem}
    .id{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all;margin:0 0 1rem}
    section,div.group{background:#fff;border:1px solid #dde1e7;border-radius:6px;padding:.25rem 1rem .75rem;margin:.5rem 0}
    div.group div.group{border-color:#e8ebef}
    dl{display:grid;grid-template-columns:minmax(8rem,14rem) 1fr;gap:.35rem 1rem;margin:.5rem 0}
    dt{color:#5a6475}dd{margin:0;word-break:break-word}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em;word-break:break-all}
    ul{margin:.25rem 0;padding-left:1.25rem}
    footer{margin-top:2rem;color:#5a6475;font-size:.875rem}
    @media (max-width:32rem){dl{grid-template-columns:1fr}dt{margin-top:.5rem}}
    @media (prefers-color-scheme:dark){body{color:#e6e9ef;background:#14171c}
    section,div.group{background:#1c2027;border-color:#323844}dt,footer{color:#9aa3b2}a{color:#8ab4ff}}
  CSS

  module_function

  # +document+ is the passport in the full representation; +url+ the address
  # it was requested at, which is where the JSON is as well.
  def render(document, url:)
    identifier = document["uniqueProductIdentifier"].to_s
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="robots" content="noindex">
      <title>Digital Product Passport #{h(identifier)}</title>
      <link rel="alternate" type="application/json" href="#{h(url)}">
      <style>#{STYLE}</style>
      </head>
      <body>
      <main>
      <h1>Digital Product Passport</h1>
      <p class="id">#{h(identifier)}</p>
      <section aria-labelledby="passport">
      <h2 id="passport">Passport</h2>
      #{header(document)}
      </section>
      #{elements_section(document["elements"])}
      <footer>
      <p>The same passport as JSON: request this address with <code>Accept: application/json</code>.</p>
      </footer>
      </main>
      </body>
      </html>
    HTML
  end

  # The page a carrier host shows for its root: what it is, and where the API is.
  def host_page(api_base:)
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Product identifiers</title>
      <style>#{STYLE}</style>
      </head>
      <body>
      <main>
      <h1>Product identifiers</h1>
      <p>This host answers the product identifiers printed on products whose digital product passport the DPP Service at <a href="#{h(api_base)}">#{h(api_base)}</a> keeps. Scan the data carrier on a product, or open its identifier, to read the passport.</p>
      </main>
      </body>
      </html>
    HTML
  end

  # The page a browser gets on a carrier host for an identifier without a
  # passport here (404).
  def not_found_page(identifier:, api_base:)
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="robots" content="noindex">
      <title>No passport for this product identifier</title>
      <style>#{STYLE}</style>
      </head>
      <body>
      <main>
      <h1>No passport found</h1>
      <p class="id">#{h(identifier)}</p>
      <p>The DPP Service at <a href="#{h(api_base)}">#{h(api_base)}</a> keeps no passport for this product identifier. Check that the address matches the one on the product or its data carrier.</p>
      </main>
      </body>
      </html>
    HTML
  end

  def header(document)
    rows = HEADER.filter_map do |key, label|
      value = document[key]
      next if value.nil? || value.to_s.empty?

      "<dt>#{h(label)}</dt><dd>#{value_html(value)}</dd>"
    end
    "<dl>#{rows.join}</dl>"
  end

  def elements_section(elements)
    list = Array(elements).select { |element| element.is_a?(Hash) }
    return "" if list.empty?

    %(<section aria-labelledby="data"><h2 id="data">Data</h2>#{elements_html(list)}</section>)
  end

  # Values in a list of definitions, collections as groups of their own.
  def elements_html(elements)
    rows = []
    out = []
    flush = -> { out << "<dl>#{rows.join}</dl>" if rows.any?; rows = [] }

    elements.each do |element|
      next unless element.is_a?(Hash)

      if element["objectType"] == "DataElementCollection"
        flush.call
        out << %(<div class="group"><h3>#{h(name(element))}</h3>#{elements_html(Array(element["elements"]))}</div>)
      else
        rows << "<dt>#{h(name(element))}</dt><dd>#{element_value_html(element)}</dd>"
      end
    end
    flush.call
    out.join
  end

  def element_value_html(element)
    case element["objectType"]
    when "SingleValuedDataElement"
      unit = element["unitOfMeasure"].to_s
      unit.empty? ? value_html(element["value"]) : "#{value_html(element['value'])} #{h(unit)}"
    when "MultiValuedDataElement"
      items = Array(element["elements"]).map do |item|
        "<li>#{item.is_a?(Hash) ? element_value_html(item) : value_html(item)}</li>"
      end
      "<ul>#{items.join}</ul>"
    when "RelatedResource"
      resource_html(element)
    else
      value_html(element.key?("value") ? element["value"] : element.except("elementId", "objectType"))
    end
  end

  def resource_html(element)
    url = element["url"].to_s
    title = element["resourceTitle"].to_s
    text = title.empty? ? url : title
    parts = [link_or_text(url, text)]
    details = [element["contentType"], element["language"]].compact.map(&:to_s).reject(&:empty?)
    parts << "<br><small>#{h(details.join(' · '))}</small>" if details.any?
    parts.join
  end

  def value_html(value)
    case value
    when Hash, Array then "<code>#{h(JSON.generate(value))}</code>"
    when String then value.match?(%r{\Ahttps?://\S+\z}) ? link_or_text(value, value) : h(value)
    else h(value.to_s)
    end
  end

  def link_or_text(url, text)
    return h(text) unless url.match?(%r{\Ahttps?://\S+\z})

    %(<a href="#{h(url)}" rel="nofollow noopener noreferrer">#{h(text)}</a>)
  end

  def name(element)
    element["elementId"].to_s.empty? ? "(unnamed)" : element["elementId"].to_s
  end

  def h(text) = ERB::Util.html_escape(text.to_s)
end
