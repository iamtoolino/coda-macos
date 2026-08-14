// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "CodaPlaybackSpike",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "CodaPlaybackSpike", targets: ["CodaPlaybackSpike"])
  ],
  targets: [
    .target(
      name: "CMpv",
      cSettings: [
        .unsafeFlags(["-I", ".build/libmpv/prefix/include"])
      ],
      linkerSettings: [
        .unsafeFlags([
          "-L", ".build/libmpv/prefix/lib",
          "-lmpv",
          "-Xlinker", "-rpath",
          "-Xlinker", "@executable_path/../Frameworks",
        ])
      ]
    ),
    .executableTarget(
      name: "CodaPlaybackSpike",
      dependencies: ["CMpv"]
    ),
    .testTarget(
      name: "CodaPlaybackSpikeTests",
      dependencies: ["CodaPlaybackSpike"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@loader_path/../../../../../libmpv/prefix/lib",
        ])
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
