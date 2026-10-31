require 'fileutils'
require 'open3'
require 'tmpdir'

# Real, disposable ad-hoc signatures. No fixture is executed and no app,
# installed signature, hardware setting, or permission is changed.
root = File.expand_path('..', __dir__)
verifier = File.join(root, 'scripts/verify-runtime.sh')
native_path = '/usr/bin:/bin:/usr/sbin:/sbin'
exception = 'com.apple.security.cs.disable-library-validation'
automation = 'com.apple.security.automation.apple-events'
audio = 'com.apple.security.device.audio-input'
count = 0

Dir.mktmpdir('sway-runtime-tests.') do |directory|
  run = lambda do |*arguments|
    output, status = Open3.capture2e({'PATH' => native_path}, *arguments)
    abort("Fixture setup failed: #{output}") unless status.success?
  end
  check = lambda do |name, entries, runtime, accepted, unsigned = false|
    binary = File.join(directory, name)
    # Only this disposable copy is re-signed. It is never launched.
    FileUtils.cp('/usr/bin/true', binary)
    if unsigned
      run.call('/usr/bin/codesign', '--remove-signature', binary)
    else
      plist = File.join(directory, "#{name}.plist")
      pairs = entries.map { |key, value| "<key>#{key}</key>#{value}" }.join
      File.write(plist, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>#{pairs}</dict></plist>")
      run.call('/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
               '--options', runtime ? 'runtime' : '0', '--entitlements', plist, binary)
    end
    output, status = Open3.capture2e({'PATH' => native_path}, '/bin/bash', verifier, binary)
    abort("Runtime verification failed for #{name}: #{output}") unless status.success? == accepted
    abort("Missing tool masked the result for #{name}: #{output}") if output.include?('command not found') || status.exitstatus == 127
    count += 1
  end
  valid = {exception => '<true/>', automation => '<true/>', audio => '<true/>'}
  check.call('native-tools-only', valid, true, true)
  check.call('missing-apple-events', {exception => '<true/>', audio => '<true/>'}, true, false)
  check.call('missing-audio-input', {exception => '<true/>', automation => '<true/>'}, true, false)
  check.call('camera-exception', valid.merge('com.apple.security.device.camera' => '<true/>'), true, false)
  check.call('false-apple-events', valid.merge(automation => '<false/>'), true, false)
  check.call('missing-runtime', valid, false, false)
  check.call('missing-entitlements', {}, true, false)
  check.call('false-exception', valid.merge(exception => '<false/>'), true, false)
  check.call('wrong-value-type', valid.merge(exception => '<string>true</string>'), true, false)
  check.call('debugger-exception', valid.merge('com.apple.security.get-task-allow' => '<true/>'), true, false)
  check.call('jit-exception', valid.merge('com.apple.security.cs.allow-jit' => '<true/>'), true, false)
  check.call('unknown-exception', valid.merge('com.example.unexpected' => '<true/>'), true, false)
  check.call('unsigned', {}, false, false, true)
end

puts "#{count} runtime-verification cases passed with macOS system tools only; no fixture was executed."
