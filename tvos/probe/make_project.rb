#!/usr/bin/env ruby
# Generates NFSU2Probe.xcodeproj next to main.m and Info.plist (gem xcodeproj).
#   BUNDLE_ID=com.you.nfsu2probe TEAM=ABCDE12345 ruby tvos/probe/make_project.rb
# BUNDLE_ID must be unique to your Apple ID; TEAM (10 characters) is optional, it can be
# chosen in Xcode under Signing & Capabilities.
require 'fileutils'
require 'xcodeproj'

dir = File.expand_path(__dir__)
path = File.join(dir, 'NFSU2Probe.xcodeproj')
FileUtils.rm_rf(path)
project = Xcodeproj::Project.new(path)
target = project.new_target(:application, 'NFSU2Probe', :tvos, '17.0')

main = project.main_group.new_file('main.m')
project.main_group.new_file('Info.plist')
target.add_file_references([main])
%w[UIKit Foundation Metal QuartzCore GameController CoreGraphics].each { |f| target.add_system_framework(f) }

target.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = ENV['BUNDLE_ID'] || 'org.nfsu2.tvprobe'
  s['INFOPLIST_FILE'] = 'Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['DEVELOPMENT_TEAM'] = ENV['TEAM'] if ENV['TEAM']
  s['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  s['TARGETED_DEVICE_FAMILY'] = '3'
  s['TVOS_DEPLOYMENT_TARGET'] = '17.0'
  s['SDKROOT'] = 'appletvos'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = ''
end
project.save
project.recreate_user_schemes
puts "wrote #{path}"
