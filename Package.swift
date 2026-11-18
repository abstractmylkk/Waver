// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Waver",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Waver", targets: ["Waver"]),
        // Audio Unit v2 effect, wrapped into Waver.component by build.sh.
        .library(name: "WaverAU", type: .dynamic, targets: ["WaverAUBridge", "WaverPlugin"]),
    ],
    targets: [
        // Pure DSP: K-weighted loudness (EBU R128 / BS.1770-4), true peak, waveform columns.
        .target(
            name: "WaverCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"])]
        ),
        // Meter UI shared by the app and the plug-in editor.
        .target(
            name: "WaverUI",
            dependencies: ["WaverCore"]
        ),
        // The standalone macOS app (SwiftUI + Core Audio taps).
        .executableTarget(
            name: "Waver",
            dependencies: ["WaverCore", "WaverUI"]
        ),
        // AUv2 plumbing in C (AudioComponentPlugInInterface).
        .target(
            name: "WaverAUBridge",
            linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreFoundation")]
        ),
        // Plug-in core + editor view (Swift side of the AU).
        .target(
            name: "WaverPlugin",
            dependencies: ["WaverCore", "WaverUI"],
            linkerSettings: [.linkedFramework("CoreAudioKit"), .linkedFramework("AudioToolbox")]
        ),
        // Offline accuracy check of the meter against known reference signals.
        .executableTarget(
            name: "WaverSelfTest",
            dependencies: ["WaverCore"]
        ),
    ]
)
