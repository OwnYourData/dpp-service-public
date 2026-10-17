# frozen_string_literal: true

namespace :funding do
  desc "Write the funding notice from config/funding.yml into the start page and the README"
  task write: :environment do
    FundingNotice.write!
    FundingNotice.copies.each { |path, _, _| puts "written: #{path.delete_prefix("#{FundingNotice::ROOT}/")}" }
  end
end
