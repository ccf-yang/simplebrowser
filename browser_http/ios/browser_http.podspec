Pod::Spec.new do |s|
  s.name             = 'browser_http'
  s.version          = '0.1.0'
  s.summary          = 'Browser-faithful HTTP client for Flutter on iOS.'
  s.description      = <<-DESC
Real TLS/HTTP2 fingerprints through a native transport, plus WKWebView
challenge hand-off and identity persistence.
                       DESC
  s.homepage         = 'https://github.com/REPLACE_ME/browser_http'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'browser_http contributors' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Rust symbols are resolved by Dart through dlsym, so the linker cannot see
    # any references to them. force_load keeps every object in the archive.
    'OTHER_LDFLAGS' =>
      '$(inherited) -Wl,-force_load,"${BUILT_PRODUCTS_DIR}/libbrowser_http_core.a" -lc++'
  }

  # Compiles rust/ into a static library for the architecture Xcode is building.
  # `rust/build_ios.sh` explains the required Rust targets.
  s.script_phase = {
    :name => 'Build Rust library',
    :script => 'sh "$PODS_TARGET_SRCROOT/../rust/build_ios.sh"',
    :execution_position => :before_compile,
    :output_files => ['${BUILT_PRODUCTS_DIR}/libbrowser_http_core.a']
  }
end
