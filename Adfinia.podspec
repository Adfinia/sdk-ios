#
# Adfinia.podspec — CocoaPods consumers.
#
# SPM consumers keep using `Package.swift` via the GitHub tag URL; this
# spec is for Xcode projects on the Podfile route. Both spec + Package.swift
# point at the same `Sources/AdfiniaSDK/**/*.swift` so they ship the same
# binary.
#
# Release flow (CI, deferred — for now bump manually):
#   1. Tag the repo `sdk-ios-v<version>` (e.g. `sdk-ios-v1.0.0`). CI fires
#      `publish-ios-sdk.yml` on tags matching `sdk-ios-v*` and runs
#      `pod trunk push` for CocoaPods + SPM picks up the same Git tag.
#   2. Update both `s.version` here AND `AdfiniaVersion.libraryVersion` in
#      Sources/AdfiniaSDK/Version.swift. The Maven publish plugin reads
#      the same version label for the Android side; the npm package
#      reads `sdks/web/package.json`. See `sdks/VERSIONING.md`.
#   3. `pod spec lint Adfinia.podspec` then `pod trunk push`.
#
# AGENT-SDK-BACKEND-CLIENT-RESUME (2026-05-22).
#

Pod::Spec.new do |s|
  s.name             = 'Adfinia'
  s.version          = '1.1.0'
  s.summary          = 'Official Adfinia SDK for iOS — first-party event + identify ingestion.'
  s.description      = <<-DESC
    Adfinia client SDK for iOS / macOS / tvOS / watchOS. Drop-in event +
    identify capture, with persistent batching, exponential backoff, and
    Kafka-first ingest against the Adfinia CDP. Honours the per-tenant
    runtime config delivered by GET /api/v1/sdk/config.
  DESC

  s.homepage         = 'https://github.com/Adfinia/sdk-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'Adfinia (New Emerging Technologies)' => 'engineering@adfinia.com' }
  s.source           = { :git => 'https://github.com/Adfinia/sdk-ios.git', :tag => "sdk-ios-v#{s.version}" }

  s.swift_versions   = ['5.9']

  s.ios.deployment_target     = '16.0'
  s.osx.deployment_target     = '13.0'
  s.tvos.deployment_target    = '16.0'
  s.watchos.deployment_target = '9.0'

  s.source_files = 'Sources/AdfiniaSDK/**/*.swift'

  s.frameworks = 'Foundation'
end
