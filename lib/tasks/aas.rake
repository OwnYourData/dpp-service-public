# frozen_string_literal: true

namespace :dpp do
  namespace :aas do
    desc "Extract the structure of the Battery Pass Data Model 1.2.0 for the AAS view (argument: path of a checkout)"
    task :extract_battery_pass, [:checkout] => :environment do |_, args|
      require "aas_template_source"

      checkout = args[:checkout].presence || abort("usage: bin/rails \"dpp:aas:extract_battery_pass[/path/to/checkout]\"")
      files = %w[
        BatteryPass/io.BatteryPass.GeneralProductInformation/1.2.0/gen/GeneralProductInformation.aas
        BatteryPass/io.BatteryPass.CarbonFootprint/1.2.0/gen/CarbonFootprintForBatteries.aas
        BatteryPass/io.BatteryPass.Circularity/1.2.0/gen/Circularity.aas
        BatteryPass/io.BatteryPass.MaterialComposition/1.2.0/gen/MaterialComposition.aas
        BatteryPass/io.BatteryPass.Performance/1.2.0/gen/PerformanceAndDurability.aas
        BatteryPass/io.BatteryPass.SupplyChainDueDiligence/1.2.0/gen/SupplyChainDueDiligence.aas
        BatteryPass/io.BatteryPass.Labels/1.2.0/gen/Labeling.aas
      ]
      commit = `git -C #{Shellwords.escape(checkout)} rev-parse HEAD`.strip
      template = AasTemplateSource.new(checkout, files).to_h(
        model: "Battery Pass Data Model", version: "1.2.0",
        repository: "https://github.com/batterypass/BatteryPassDataModel", commit: commit, license: "CC-BY-4.0"
      )
      target = Rails.root.join("app/lib/aas_view/battery_pass_1_2_0.json")
      target.write("#{JSON.pretty_generate(template)}\n")
      puts "written: #{target.relative_path_from(Rails.root)} (#{template['submodels'].size} submodels, commit #{commit[0, 7]})"
    end
  end
end
