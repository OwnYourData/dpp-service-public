# frozen_string_literal: true

# Subscriptions to the notifications about new Delegated Acts
# (NewsletterSubscription, docs/Newsletter.md). Only what the subscription
# needs: the address, the language, and when it was requested and confirmed
# (to show the consent). No IP address, no name, no tracking.
class CreateNewsletterSubscriptions < ActiveRecord::Migration[7.2]
  def change
    create_table :newsletter_subscriptions do |t|
      t.string :email, null: false
      t.string :locale, null: false
      t.datetime :requested_at, null: false
      t.datetime :confirmed_at
    end
    add_index :newsletter_subscriptions, :email, unique: true
    add_index :newsletter_subscriptions, :requested_at
  end
end
