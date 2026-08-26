# frozen_string_literal: true

# A Digital Product Passport instance.
#
# The header attributes of the EN 18223:2026 semantic model (Table 1) are stored
# as columns for querying; the full DPP document (header + elements
# + dataElements) is kept in +content+ as the single source of truth.
class Dpp < ApplicationRecord
  self.primary_key = "dpp_id"

  STATUSES     = %w[Active Archived].freeze
  GRANULARITIES = %w[model batch item].freeze

  # NOT dependent: :destroy — DeleteDPPById archives the current version and
  # removes the active passport; the archived versions must survive so that
  # ReadDPPVersionByIdAndDate keeps working (EN 18221:2026 4.2).
  has_many :dpp_versions, foreign_key: "dpp_id", primary_key: "dpp_id",
                          dependent: nil, inverse_of: :dpp

  validates :dpp_id, :product_id, :dpp_schema_version, :economic_operator_id, presence: true
  validates :dpp_status, inclusion: { in: STATUSES }
  validates :granularity, inclusion: { in: GRANULARITIES }

  # The product identifier has to be carrier-borne (see ProductIdentifier).
  # On create only: passports minted before the carrier redesign carry opaque
  # identifiers and must stay updatable.
  validate :product_id_is_a_carrier_identifier, on: :create
  before_validation :assign_product_key

  scope :active, -> { where(dpp_status: "Active") }

  # The Unique Product Identifier registered at the EU Registry.
  #
  # EN 18219:2026 3.1.25 defines it as *one* string that identifies the product and
  # "also enables a web link to the digital product passport", and §4.5.2 (1)
  # requires that same string to be retrievable from the data carrier. It is
  # therefore the product identifier itself -- no second carrier token exists.
  #
  # The host belongs to the economic operator and is pointed at the custodian by
  # CNAME, so changing custodian leaves printed carriers intact, which is what
  # 4.6.2 (3) (no vendor lock-in), 4.5.2 (4) (existing ID) and 3.1.25 (usable
  # outside the issuing assigner's control) ask for.
  def upi
    product_id
  end

  # --- storage backend (S2: hosting pod of the data intermediary) --------------

  STORAGE_BACKENDS = %w[local pod].freeze
  validates :storage_backend, inclusion: { in: STORAGE_BACKENDS }

  # True when the DPP document lives in a hosting pod instead of this database.
  def pod?
    storage_backend == "pod"
  end

  def pod_storage
    @pod_storage ||= PodStorage.for(self)
  end

  # Attach a pod as the storage backend. What is kept is the delegation the
  # economic operator signed (docs/Delegation.md §9) — in the clear, because
  # without the private key of the service DID it is worth nothing to anyone.
  # No credential of the customer is stored here any more.
  def assign_pod_storage!(storage)
    # from_document put the inbound document into +content+; move it out so
    # nothing of the payload stays in this database.
    document = content.presence || {}
    self.storage_backend       = "pod"
    self.storage_base_url      = storage.base_url
    self.storage_collection_id = storage.collection_id
    self.storage_delegation    = storage.storage_delegation
    @pod_storage = storage
    self.document_content = document
    self
  end

  # The DPP document: locally the +content+ column, for a pod-backed DPP a
  # read-through fetch from the pod (cached for the lifetime of this instance).
  def document_content
    return content || {} unless pod?
    return @document_content if defined?(@document_content) && @document_content

    @document_content = storage_object_id.present? ? pod_storage.read_payload(storage_object_id) : {}
  end

  def document_content=(value)
    if pod?
      @document_content = value
      self.content = {}          # nothing of the payload stays behind locally
    else
      self.content = value
    end
  end

  # Hand the passport to a different custodian.
  #
  # The document is read from the current pod while that one is still
  # authoritative, then written into the new one under a fresh card. What is
  # returned describes the previous custody so the caller can end it -- as a
  # separate act, not as a side effect of this one.
  #
  # Deliberately NOT touched here: the old pod. The overlap is the rollback path
  # while a carrier may still resolve to the old host, and the version history
  # lives in the pod (EN 18221:2026 4.2 requires archived versions to be retained), so
  # releasing before the new custodian has been seen to answer would discard
  # exactly what has to be kept.
  def move_to_pod!(storage)
    raise ArgumentError, "only a pod-backed passport can be moved" unless pod?

    document = to_document
    previous = { storage: pod_storage, object_id: storage_object_id,
                 base_url: storage_base_url, collection_id: storage_collection_id }

    self.storage_base_url      = storage.base_url
    self.storage_collection_id = storage.collection_id
    self.storage_delegation    = storage.storage_delegation
    self.storage_object_id     = nil
    @pod_storage               = storage
    self.document_content      = document
    save!
    store_in_pod!

    previous
  end

  # Push the current document into the pod. Creates the card on first use.
  def store_in_pod!
    return false unless pod?

    if storage_object_id.blank?
      update_column(:storage_object_id, pod_storage.create_object(self))
    end
    pod_storage.write_payload(storage_object_id, to_document)
    true
  end

  # --- did:oyd private key material (Variante A) ------------------------------
  # Stored encrypted (KeyVault) in the *_enc columns; accessed in the clear via
  # these helpers. Never exposed through to_document.
  def did_doc_key = KeyVault.decrypt(did_doc_key_enc)
  def did_rev_key = KeyVault.decrypt(did_rev_key_enc)
  def did_rev_log = KeyVault.decrypt(did_rev_log_enc)

  def did_doc_key=(value)
    self.did_doc_key_enc = KeyVault.encrypt(value)
  end

  def did_rev_key=(value)
    self.did_rev_key_enc = KeyVault.encrypt(value)
  end

  def did_rev_log=(value)
    self.did_rev_log_enc = KeyVault.encrypt(value)
  end

  # Attach a freshly minted did:oyd (from DidOyd.mint) to this DPP.
  def assign_minted_did!(minted)
    self.dpp_id      = minted[:did]
    self.did_managed = true
    self.did_doc_key = minted[:doc_key]
    self.did_rev_key = minted[:rev_key]
    self.did_rev_log = minted[:rev_log]
  end

  # Build a Dpp from an inbound DPP document (EN 18223:2026 Table 1).
  def self.from_document(doc)
    doc = doc.with_indifferent_access
    new(
      dpp_id:               doc[:digitalProductPassportId],
      product_id:           doc[:uniqueProductIdentifier],
      granularity:          doc[:granularity],
      dpp_schema_version:   doc[:dppSchemaVersion],
      dpp_status:           doc[:dppStatus] || "Active",
      economic_operator_id: doc[:economicOperatorId],
      facility_id:          doc[:facilityId],
      last_update:          Time.now.utc,
      content:              doc.to_h
    )
  end

  # The DPP document as returned to clients: exactly the attributes of
  # EN 18223:2026 Table 1, "Attributes of the DigitalProductPassport class".
  #
  # There is no separate UPI attribute, and the published edition makes the
  # reason plain by naming the attribute +uniqueProductIdentifier+ and defining
  # it as "unique string of characters for the identification of a product, that
  # also enables a web link to the digital product passport" -- the product
  # identifier and the unique product identifier are one value, as EN 18219
  # 3.1.25 also has it. Carrying it twice would be a proprietary attribute and
  # would break conformance for every reader.
  def to_document
    (document_content || {}).merge(
      "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier"  => product_id,
      "granularity"              => granularity,
      "dppSchemaVersion"         => dpp_schema_version,
      "dppStatus"                => dpp_status,
      "lastUpdated"              => last_update&.iso8601,
      "economicOperatorId"       => economic_operator_id,
      "facilityId"               => facility_id
    ).compact
  end

  # EN 18222:2026 4.7: every change shall be archived (EN 18221:2026 4.2).
  # The snapshot holds the state *before* the change.
  #
  # For a pod-backed DPP this is a no-op: the pod archives on its own — a
  # changed payload becomes a new object (the old one stays retrievable under
  # its DRI) and is logged with a timestamp. Writing a second copy here would
  # duplicate the history and let the two drift apart.
  def archive_current_version!
    return nil if pod?

    next_no = (DppVersion.where(dpp_id: dpp_id).maximum(:version_number) || 0) + 1
    DppVersion.create!(
      dpp_id:         dpp_id,
      product_id:     product_id,
      version_number: next_no,
      dpp_status:     dpp_status,
      content:        to_document,
      archived_at:    Time.now.utc
    )
  end

  # Apply an RFC 7396 merge patch to the DPP document and persist.
  # For a pod-backed DPP the new document goes to the pod, which archives the
  # previous one on its own.
  def apply_merge_patch!(patch)
    archive_current_version!
    merged = JsonMergePatch.apply(to_document, patch.deep_stringify_keys)
    assign_from_document(merged)
    save!
    store_in_pod!
    self
  end

  private

  # The host-independent part of the product identifier: the lookup key at the
  # custodian, which is what lets one store serve any number of operator-owned
  # hostnames. nil for an identifier no scheme of EN 18219:2026 Clause 5 covers.
  def assign_product_key
    return if product_id.blank?

    self.product_key = ProductIdentifier.new(product_id).product_key
  end

  def product_id_is_a_carrier_identifier
    return if product_id.blank?

    ProductIdentifier.parse!(product_id).assert_granularity!(granularity)
  rescue ProductIdentifier::InvalidError => e
    errors.add(:product_id, e.message)
  end

  def assign_from_document(doc)
    doc = doc.with_indifferent_access
    self.granularity        = doc[:granularity] if doc.key?(:granularity)
    self.dpp_schema_version = doc[:dppSchemaVersion] if doc.key?(:dppSchemaVersion)
    self.dpp_status         = doc[:dppStatus] if doc.key?(:dppStatus)
    self.facility_id        = doc[:facilityId] if doc.key?(:facilityId)
    self.last_update        = Time.now.utc
    self.document_content   = doc.to_h
  end
end
