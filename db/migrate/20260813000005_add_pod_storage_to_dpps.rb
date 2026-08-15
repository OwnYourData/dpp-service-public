# frozen_string_literal: true

# Stufe S2: die DPP-Inhalte koennen statt lokal in einem vom Datenintermediaer
# verwalteten Hosting-Pod liegen. Die Zuordnung erfolgt pro DPP.
#
# storage_backend
#   "local" -> unveraendertes Verhalten, das Dokument steht in dpps.content
#   "pod"   -> das Dokument liegt im Pod; content bleibt leer
#
# storage_credentials_enc haelt das Storage-JWT (base_url, collection_id,
# client_id, client_secret) verschluesselt (KeyVault, AES-256-GCM) - es enthaelt
# mit client_secret ein Geheimnis und darf nie im Klartext gespeichert oder
# ausgegeben werden.
class AddPodStorageToDpps < ActiveRecord::Migration[7.1]
  def change
    add_column :dpps, :storage_backend, :string, null: false, default: "local"
    add_column :dpps, :storage_base_url, :string       # z.B. https://dpp.go-data.at
    add_column :dpps, :storage_collection_id, :string  # Collection im Pod
    add_column :dpps, :storage_object_id, :string      # object-id der Karteikarte
    add_column :dpps, :storage_credentials_enc, :text  # verschluesseltes Storage-JWT

    add_index :dpps, :storage_backend
  end
end
