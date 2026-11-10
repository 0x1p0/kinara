require 'yaml'
require 'rexml/document'

root = File.expand_path('..', __dir__)
release = YAML.load_file(File.join(root, '.github/workflows/release.yml'))
checks = YAML.load_file(File.join(root, '.github/workflows/checks.yml'))
count = 0
expect = lambda do |condition, message|
  abort("Release policy failed: #{message}") unless condition
  count += 1
end
build = release.fetch('jobs').fetch('build')
sign = release.fetch('jobs').fetch('release')
app_sign = release.fetch('jobs').fetch('sign-app')
package = release.fetch('jobs').fetch('package')
expect.call(release.fetch('permissions') == {'contents' => 'read'}, 'read-only workflow default')
expect.call(build.fetch('permissions') == {'contents' => 'read'}, 'build must not write to repository')
expect.call(!build.key?('environment') && !build.to_s.include?('secrets.'), 'build must have no protected environment or secrets')
expect.call(app_sign.fetch('needs') == 'build', 'app signing requires successful build')
expect.call(package.fetch('needs') == 'sign-app', 'packaging requires app signing')
expect.call(sign.fetch('needs') == ['sign-app', 'package'], 'publishing requires both signed app and packaging')
expect.call(app_sign.fetch('environment') == 'release', 'app identity requires release approval')
expect.call(app_sign.fetch('permissions') == {'contents' => 'read'}, 'app signer cannot publish')
expect.call(package.fetch('permissions') == {'contents' => 'read'} && !package.key?('environment') && !package.to_s.include?('secrets.'), 'packaging dependencies must never receive keys')
app_steps = app_sign.fetch('steps')
app_checkout = app_steps.find { |step| step['uses'].to_s.start_with?('actions/checkout@') }
expect.call(app_checkout.fetch('with').fetch('ref') == 'main' && app_checkout.fetch('with').fetch('persist-credentials') == false, 'app signer uses protected source without persisted credentials')
expect.call(app_steps.any? { |step| step['run'].to_s.include?('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"') }, 'app signer requires current main')
app_secret_steps = app_steps.select { |step| step.fetch('env', {}).key?('KINARA_APP_SIGNING_IDENTITY') }
expect.call(app_secret_steps.length == 1 && app_secret_steps.first.fetch('run') == 'python3 scripts/app-signing.py sign "$RUNNER_TEMP/kinara-app/Kinara.app"', 'only the dependency-free app signer receives the identity')
expect.call(!app_sign.to_s.include?('SPARKLE_PRIVATE_KEY') && !sign.to_s.include?('KINARA_APP_SIGNING_IDENTITY'), 'separate app and update signing steps/runners')
expect.call(app_steps.map { |step| step['run'] }.join("\n") !~ /pip|setup-dmg|setup-sparkle|test-updater|package-release|xcodebuild/, 'app signer must not run build dependencies or artifact code')
expect.call(sign.fetch('environment').fetch('name') == 'release', 'release approval environment required')
steps = sign.fetch('steps')
checkout = steps.find { |step| step['uses'].to_s.start_with?('actions/checkout@') }
expect.call(checkout.fetch('with').fetch('ref') == 'main', 'signing tools must come from protected main')
expect.call(checkout.fetch('with').fetch('persist-credentials') == false, 'do not persist repository credentials')
expect.call(steps.any? { |step| step['run'].to_s.include?('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"') }, 'release source must equal protected main')
download = steps.find { |step| step['uses'].to_s.start_with?('actions/download-artifact@') }
expect.call(download.fetch('with').fetch('artifact-ids') == '${{ needs.package.outputs.artifact-id }}', 'download exact artifact ID from packaging')
expect.call(download.fetch('with').fetch('path') == '${{ runner.temp }}/kinara-release', 'artifacts must not overwrite signing sources or executables')
expect.call(download.fetch('with').fetch('digest-mismatch') == 'error', 'artifact integrity failures must stop the release')
secret_steps = steps.select { |step| step.fetch('env', {}).key?('SPARKLE_PRIVATE_KEY') }
expect.call(secret_steps.length == 1, 'only one step receives the signing key')
expect.call(secret_steps.first.fetch('run').include?('"$RUNNER_TEMP/kinara-sign-update"'), 'invoke the precompiled signer')
expect.call(secret_steps.first.fetch('run') !~ /xcrun|swiftc|pip|bash|unzip|ditto|curl/, 'do not build, download, or unpack while holding the key')
verification = steps.find { |step| step['run'].to_s.include?('scripts/verify-release-downloads.py') }
expect.call(verification && steps.index(verification) < steps.index(secret_steps.first), 'verify app/DMG before update-key access')
expect.call(verification.fetch('env').fetch('SIGNED_ZIP_SHA256') == '${{ needs.sign-app.outputs.zip-sha256 }}', 'ZIP digest must come from app signer, not packager')
expect.call(steps.map { |step| step['run'] }.join("\n") !~ /generate_appcast|package-release|setup-sparkle|setup-dmg|test-updater|pip install/, 'signing runner must not run build dependencies or downloaded apps')
expect.call(sign.fetch('permissions') == {'contents' => 'write'}, 'release job gets only publishing permissions')
events = checks['on'] || checks[true] # YAML 1.1 treats "on" as a boolean.
expect.call(events.key?('pull_request') && !events.key?('pull_request_target'), 'PR checks must be unprivileged')
expect.call(checks.fetch('permissions') == {'contents' => 'read'}, 'PR token must be read-only')
expect.call(checks.fetch('jobs').fetch('checks').fetch('name') == 'Kinara checks', 'required status-check name must stay stable')
expect.call(!checks.to_s.include?('secrets.'), 'PR checks must never reference secrets')
[build, checks.fetch('jobs').fetch('checks')].each do |job|
  expect.call(job.fetch('steps').any? { |step| step['run'].to_s.include?('ruby Tests/runtime_verification_regressions.rb') }, 'both build paths must test runtime verification without optional tools')
  identity_test = job.fetch('steps').find { |step| step['name'] == 'Test temporary app-signing identity' }
  expect.call(identity_test && identity_test.fetch('run').include?('python3 Tests/app_signing_regressions.py'), 'both build paths must gate releases on disposable signing and cleanup tests')
  expect.call(job.fetch('steps').any? { |step| step['run'].to_s.include?('python3 Tests/package_release_regressions.py') }, 'both build paths must test packaging without a pre-existing build directory')
end
[release, checks].each do |workflow|
  workflow.fetch('jobs').each_value do |job|
    job.fetch('steps').each do |step|
      next unless step['uses']
      expect.call(step['uses'].match?(/\Aactions\/[a-z-]+@[0-9a-f]{40}\z/), 'actions must be pinned to official immutable commits')
    end
  end
end
entitlements = REXML::Document.new(File.read(File.join(root, 'Kinara/Kinara.entitlements')))
keys = REXML::XPath.match(entitlements, '//key').map(&:text)
expect.call(keys == ['com.apple.security.cs.disable-library-validation', 'com.apple.security.automation.apple-events', 'com.apple.security.device.audio-input'], 'only the documented cross-signer, Apple Events and audio-input entitlements are allowed')
build_script = File.read(File.join(root, 'scripts/build.sh'))
expect.call(build_script.include?('--options runtime') && build_script.include?('scripts/verify-runtime.sh'), 'runtime must be enabled and checked in release builds')
signer = File.read(File.join(root, 'scripts/sign-update.swift'))
expect.call(!signer.include?('Process(') && !signer.include?('Bundle('), 'signer must not execute or load artifact code')
puts "#{count} release-security policy assertions passed."
