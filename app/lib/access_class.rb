# frozen_string_literal: true

require "json"

# The controlled vocabulary of access classes (EN 18239:2026: access rights are
# defined per property and through controlled vocabularies, because roles change
# over time). One class says who may read an attribute of a passport:
#
#   public              anyone, without authentication
#   legitimateInterest  actors with a legitimate interest, and authorities
#   authority           authorities only
#
# The classes are ordered by +level+: whoever may read a class may read every
# class below it. The three match the access groups of the Battery Regulation
# (Regulation (EU) 2023/1542, Article 77(2)). Which role reads which class is
# not part of the vocabulary.
#
# The vocabulary itself is config/vocab/dpp-access-v1.jsonld, a SKOS concept
# scheme under https://w3id.org/soya/dpp-access/v1. This module reads that file,
# so the code and the published vocabulary cannot drift apart.
module AccessClass
  SCHEME = "https://w3id.org/soya/dpp-access/v1"
  FILE   = File.expand_path("../../config/vocab/dpp-access-v1.jsonld", __dir__)

  class UnknownError < StandardError; end

  Concept = Struct.new(:notation, :iri, :level, keyword_init: true) do
    include Comparable

    def <=>(other) = level <=> other.level
    def to_s = notation
  end

  module_function

  # All concepts, lowest level first.
  def all
    @all ||= load_concepts
  end

  def notations = all.map(&:notation)

  # A concept by its notation ("public") or its IRI.
  def resolve(value)
    text = value.to_s
    all.find { |concept| concept.notation == text || concept.iri == text } ||
      raise(UnknownError, "#{text.inspect} is not an access class of #{SCHEME} " \
                          "(known: #{notations.join(', ')})")
  end

  def public_class = resolve("public")
  def most_restrictive = all.last

  # The classes a reader with +roles+ may read: public, and every class up to
  # the highest one named. A role is the notation or IRI of a class; whoever
  # may read a class may read every class below it. Roles that are not classes
  # of the vocabulary open nothing.
  def readable_with(roles)
    granted = Array(roles).filter_map do |role|
      resolve(role)
    rescue UnknownError
      nil
    end
    top = granted.max || public_class
    all.select { |concept| concept <= top }
  end

  def load_concepts
    graph = JSON.parse(File.read(FILE)).fetch("@graph")
    graph.select { |node| node["@type"] == "skos:Concept" && node["inScheme"] == SCHEME }
         .map { |node| Concept.new(notation: node.fetch("skos:notation"), iri: node.fetch("@id"),
                                   level: Integer(node.fetch("level"))).freeze }
         .sort_by(&:level)
         .freeze
  end
  private_class_method :load_concepts
end
