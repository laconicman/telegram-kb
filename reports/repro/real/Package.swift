// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TraitRepro",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TraitRepro", targets: ["TraitRepro"])],
    traits: [.trait(name: "TDLib")],          // not a default trait -> disabled
    dependencies: [
        .package(url: "https://github.com/Swiftgram/TDLibKit.git",
                 exact: "1.5.2-tdlib-1.8.66-022d6020"),
    ],
    targets: [
        .target(name: "TraitRepro", dependencies: [
            .product(name: "TDLibKit", package: "TDLibKit",
                     condition: .when(traits: ["TDLib"]))
        ]),
    ])
