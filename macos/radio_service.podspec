#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint radio_service.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'radio_service'
  s.version          = '0.1.7'
  s.summary          = 'Internet radio playback with ICY metadata, artwork and background audio.'
  s.description      = <<-DESC
Flutter plugin for internet radio streaming. NOT YET IMPLEMENTED on this
platform: the sources here are the generated skeleton, kept as a starting
point for the port. The plugin only declares Android in its pubspec.yaml.
                       DESC
  s.homepage         = 'https://github.com/gcimia/radio_service'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'gcimia' => 'gcimia.dev@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'

  # If your plugin requires a privacy manifest, for example if it collects user
  # data, update the PrivacyInfo.xcprivacy file to describe your plugin's
  # privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'radio_service_privacy' => ['Resources/PrivacyInfo.xcprivacy']}

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
