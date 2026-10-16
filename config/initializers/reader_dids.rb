# frozen_string_literal: true

# Reads the reader DIDs once at start-up and says in the log which reader
# serves which pod, or why the configuration was refused (ReaderDid). Local
# checks only; whether each DID resolves to its key is `bin/rails
# dpp:readers:check`, which needs the network.
Rails.application.config.after_initialize do
  ReaderDid.boot_check unless Rails.env.test?
end
