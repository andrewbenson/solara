engine_public = File.expand_path('../../../engine/solaracore/src/solara/core/public', __dir__)

Pod::Spec.new do |s|
  s.name           = 'SolaraCore'
  s.version        = '0.0.0'
  s.summary        = 'Solara on SolaraCore (our own Chromium layer) for React Native macOS'
  s.author         = ''
  s.homepage       = 'https://github.com/solara'
  s.license        = 'Apache-2.0'
  s.platforms      = { :osx => '14.0' }
  s.source         = { git: '' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.frameworks     = 'WebKit'
  s.source_files   = '*.{h,mm,swift}'
  s.public_header_files = 'SolaraCoreHost.h', 'SolaraCoreWebView.h', 'SolaraCoreTabStrip.h', 'SolaraCoreEngineBridge.h', 'SolaraCoreServices.h', 'SolaraCoreNotifications.h', 'ACSwipe.h', 'ACChromeWindow.h'
  s.resources      = 'page_script.js'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => "\"#{engine_public}\"",
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
  }
end
