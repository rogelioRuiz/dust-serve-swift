Pod::Spec.new do |s|
  s.name         = 'DustServe'
  s.version      = File.read(File.join(__dir__, 'VERSION')).strip
  s.summary      = 'Standalone model server business logic for iOS'
  s.license      = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.homepage     = 'https://github.com/rogelioRuiz/dust-serve-swift'
  s.author       = 'Techxagon'
  s.source       = { :git => 'https://github.com/rogelioRuiz/dust-serve-swift.git', :tag => s.version.to_s }

  s.source_files = 'Sources/DustServe/**/*.swift'
  s.ios.deployment_target = '16.0'

  s.dependency 'DustCore'
  s.swift_version = '5.9'
end
