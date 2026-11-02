Pod::Spec.new do |s|
  s.name           = 'SolaraSettingsAdapter'
  s.version        = '0.0.0'
  s.summary        = 'The native Settings window (SolaraUI) and the calls it makes into JS'
  s.author         = ''
  s.homepage       = 'https://github.com/andrewbenson/solara'
  s.license        = 'Apache-2.0'
  s.platforms      = { :osx => '26.0' }
  s.source         = { git: '' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.dependency 'SolaraStoreAdapter'
  s.dependency 'SolaraShell'
  s.dependency 'SolaraShaders'
  s.dependency 'SolaraSyncAdapter'
  s.dependency 'SolaraCore'
  s.frameworks     = 'AppKit', 'SwiftUI'
  s.source_files   = '**/*.swift'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'SWIFT_VERSION' => '6.0' }
end
