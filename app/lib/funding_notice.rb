# frozen_string_literal: true

require "erb"
require "yaml"

# The funding notice of PACE-DPP, kept once in config/funding.yml.
#
# Two places show it: the footer of the start page and the README. Both hold a
# copy between two markers, and `bin/rails funding:write` replaces that copy
# with what the configuration says. The spec compares them, so a copy that was
# not rewritten does not go unnoticed.
module FundingNotice
  ROOT = File.expand_path("../..", __dir__)
  SOURCE = File.join(ROOT, "config", "funding.yml")
  BEGIN_MARK = "<!-- funding:begin -->"
  END_MARK = "<!-- funding:end -->"
  LINK = /\[([^\]]+)\]\(([^)\s]+)\)/

  module_function

  def settings
    YAML.safe_load_file(SOURCE)
  end

  # For the README: Markdown, with the full title of the project.
  def markdown
    s = settings
    format(s.fetch("text"), component: s.fetch("component"), title: " – #{s.fetch('title')}")
  end

  # For the footer: one line of HTML, without the title.
  def html
    s = settings
    text = format(s.fetch("text"), component: s.fetch("component"), title: "")
    String.new(ERB::Util.html_escape(text)).gsub(LINK) { %(<a href="#{Regexp.last_match(2)}">#{Regexp.last_match(1)}</a>) }
  end

  # The README that is published. In this repository it is kept apart from the
  # internal one, under .publish-overlay/, and becomes README.md on publishing.
  def readme
    kept = File.join(ROOT, ".publish-overlay", "README.md")
    File.exist?(kept) ? kept : File.join(ROOT, "README.md")
  end

  # Each copy: the file, the text it should hold, and what separates the text
  # from the markers (a line break in Markdown, nothing inside the footer).
  def copies
    [
      [File.join(ROOT, "app", "views", "landing", "show.html.erb"), html, ""],
      [readme, markdown, "\n"]
    ]
  end

  def current(path)
    content = File.read(path, encoding: "UTF-8")
    start = content.index(BEGIN_MARK) or return nil
    stop = content.index(END_MARK, start) or return nil
    content[(start + BEGIN_MARK.length)...stop].strip
  end

  def write!
    copies.each do |path, text, gap|
      content = File.read(path, encoding: "UTF-8")
      region = /#{Regexp.escape(BEGIN_MARK)}.*?#{Regexp.escape(END_MARK)}/m
      raise "#{path}: no funding markers" unless content.match?(region)

      File.write(path, content.sub(region) { "#{BEGIN_MARK}#{gap}#{text}#{gap}#{END_MARK}" })
    end
  end
end
