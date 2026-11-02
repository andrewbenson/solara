Pod::Spec.new do |s|
  s.name           = 'SolaraStoreAdapter'
  s.version        = '0.0.0'
  s.summary        = 'The native Swift store (SolaraKit) exposed to JS'
  s.author         = ''
  s.homepage       = 'https://github.com/andrewbenson/solara'
  s.license        = 'Apache-2.0'
  s.platforms      = { :osx => '26.0' }
  s.source         = { git: '' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.dependency 'SolaraCore'
  s.dependency 'SolaraSyncAdapter'
  s.frameworks     = 'AppKit'
  s.source_files   = '*.swift'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'SWIFT_VERSION' => '6.0' }
end
