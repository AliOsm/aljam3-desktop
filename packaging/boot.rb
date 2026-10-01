# frozen_string_literal: true

# Shared by the .app and .exe launchers. No installed Ruby, Bundler, or mise is used.
Encoding.default_external = Encoding::UTF_8
ENV["SCARPE_DISPLAY_SERVICE"] = "native"
ENV["ALJAM3_BUNDLE_ROOT"] = __dir__
ENV["SSL_CERT_FILE"] = File.join(__dir__, "ruby/lib/ca-bundle.crt")
ENV.delete("SSL_CERT_DIR")
ENV.delete("SQLITE_TOKENIZER_AR_EXTENSION")
require "rubygems"
Gem.use_paths(File.join(__dir__, "gems"), [File.join(__dir__, "ruby/lib/ruby/gems/3.4.0")])
%w[lib lacci/lib scarpe-components/lib].each { |path| $LOAD_PATH.unshift(File.join(__dir__, "scarpe", path)) }
require "scarpe"
Shoes.run_app(ENV.fetch("SCARPE_RUN_FILE", File.join(__dir__, "app/app.rb")))
