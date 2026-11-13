# SPDX-License-Identifier: GPL-3.0-or-later
Pod::Spec.new do |s|
  s.name             = 'pairdesk_ios'
  s.version          = '0.1.0'
  s.summary          = "PairDesk's iPhone-only native side."
  s.description      = <<-DESC
The pairdesk/files channel on iPhone (choosing files, received files in the
Files app, Quick Look, pairdesk:// links), plus sound and screen video.
                       DESC
  s.homepage         = 'https://github.com/sandunMadhushan/pairdesk'
  s.license          = { :type => 'GPL-3.0-or-later' }
  s.author           = { 'Sandun Madhushan' => 'https://github.com/sandunMadhushan' }
  s.source           = { :path => '.' }
  s.source_files     = 'pairdesk_ios/Sources/pairdesk_ios/**/*.swift'
  s.dependency 'Flutter'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDE_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.frameworks       = 'QuickLook', 'UniformTypeIdentifiers', 'AVFoundation', 'VideoToolbox'
end
