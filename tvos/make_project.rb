#!/usr/bin/env ruby
# Generates tvos/NFSU2.xcodeproj (gem xcodeproj): the app around libnfsu2.a.
#   BUNDLE_ID=com.you.nfsu2 TEAM=ABCDE12345 ruby tvos/make_project.rb
# A Run Script phase runs tvos/build.sh first (for the SDK being built), so Cmd+R rebuilds the
# library when the runtime or the shards changed.  The game folder is added as a folder
# reference: GAME="path/to/Need for Speed Underground 2" (default: ../NFS Underground 2).
require 'fileutils'
require 'xcodeproj'

dir = File.expand_path(__dir__)
path = File.join(dir, 'NFSU2.xcodeproj')
FileUtils.rm_rf(path)
project = Xcodeproj::Project.new(path)
target = project.new_target(:application, 'NFSU2', :tvos, '17.0')

app = project.main_group.new_group('app', 'app')
main = app.new_file('main.m')
app.new_file('Info.plist')
target.add_file_references([main])

# the game's own files and the first-run registry
reg = project.main_group.new_file('../app/registry-defaults.txt')
game = ENV['GAME'] || File.join(dir, '..', 'NFS Underground 2')
gref = project.main_group.new_reference(File.expand_path(game))
gref.last_known_file_type = 'folder'
assets = app.new_file('Assets.xcassets')
target.resources_build_phase.add_file_reference(assets)
target.resources_build_phase.add_file_reference(reg)
target.resources_build_phase.add_file_reference(gref)

# the library, rebuilt for the SDK being built
sp = target.new_shell_script_build_phase('Build libnfsu2.a')
sp.shell_script = %q(SDK="$PLATFORM_NAME" "$SRCROOT/build.sh")
sp.always_out_of_date = '1'
target.build_phases.delete(sp)
target.build_phases.insert(0, sp)

%w[UIKit Foundation Metal QuartzCore GameController CoreGraphics AudioToolbox AVFoundation ImageIO CoreServices GameKit].each do |f|
  target.add_system_framework(f)
end

target.build_configurations.each do |c|
  s = c.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = ENV['BUNDLE_ID'] || 'org.nfsu2.tv'
  s['PRODUCT_NAME'] = 'NFSU2'
  s['INFOPLIST_FILE'] = 'app/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['DEVELOPMENT_TEAM'] = ENV['TEAM'] if ENV['TEAM']
  s['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  s['TARGETED_DEVICE_FAMILY'] = '3'
  s['TVOS_DEPLOYMENT_TARGET'] = '17.0'
  s['SDKROOT'] = 'appletvos'
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['ENABLE_BITCODE'] = 'NO'
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'App Icon & Top Shelf Image'
  s['MARKETING_VERSION'] = ENV['VERSION'] || '0.1'
  s['CURRENT_PROJECT_VERSION'] = ENV['BUILD'] || '1'
  s['LIBRARY_SEARCH_PATHS[sdk=appletvos*]'] = '$(SRCROOT)/../out/tvos'
  s['LIBRARY_SEARCH_PATHS[sdk=appletvsimulator*]'] = '$(SRCROOT)/../out/tvos-sim'
  s['OTHER_LDFLAGS'] = '-lnfsu2 -lz'
  s['CODE_SIGN_ENTITLEMENTS'] = 'app/NFSU2.entitlements'
end
project.save
project.recreate_user_schemes
puts "wrote #{path}"
