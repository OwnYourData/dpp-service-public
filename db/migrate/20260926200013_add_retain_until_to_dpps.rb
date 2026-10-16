# frozen_string_literal: true

# The last day a passport has to stay available (ESPR Art. 9(2)(i)).
#
# Set at CreateDPP from the X-DPP-Retain-Until header, which the economic
# operator works out from the period its product group prescribes. Until that
# day DeleteDPPById is refused, whoever asks. NULL for a passport created
# without one, which can be deleted as before.
class AddRetainUntilToDpps < ActiveRecord::Migration[7.2]
  def change
    add_column :dpps, :retain_until, :date
  end
end
