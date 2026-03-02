<p align="center">
  <img alt="dust" src="assets/dust_banner.png" width="400">
</p>

<p align="center">
  <strong>Device Unified Serving Toolkit</strong><br>
  <a href="https://github.com/rogelioRuiz/dust">dust ecosystem</a> · v0.1.0 · Apache 2.0
</p>

<p align="center">
  <a href="https://github.com/rogelioRuiz/dust/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/badge/License-Apache_2.0-blue.svg"></a>
  <img alt="Version" src="https://img.shields.io/badge/version-0.1.0-informational">
  <img alt="SPM" src="https://img.shields.io/badge/SPM-DustServe-F05138">
  <img alt="CocoaPods" src="https://img.shields.io/badge/CocoaPods-DustServe-EE3322">
  <a href="https://swift.org"><img alt="Swift" src="https://img.shields.io/badge/Swift-5.9-orange.svg"></a>
  <img alt="Platforms" src="https://img.shields.io/badge/Platforms-iOS_16+_|_macOS_13+-lightgrey">
  <a href="https://github.com/rogelioRuiz/dust-serve-swift/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/rogelioRuiz/dust-serve-swift/actions/workflows/ci.yml/badge.svg?branch=main"></a>
</p>

---

<p align="center">
<strong>dust ecosystem</strong> —
<a href="../capacitor-core/README.md">capacitor-core</a> ·
<a href="../capacitor-llm/README.md">capacitor-llm</a> ·
<a href="../capacitor-onnx/README.md">capacitor-onnx</a> ·
<a href="../capacitor-serve/README.md">capacitor-serve</a> ·
<a href="../capacitor-embeddings/README.md">capacitor-embeddings</a>
<br>
<a href="../dust-core-kotlin/README.md">dust-core-kotlin</a> ·
<a href="../dust-llm-kotlin/README.md">dust-llm-kotlin</a> ·
<a href="../dust-onnx-kotlin/README.md">dust-onnx-kotlin</a> ·
<a href="../dust-embeddings-kotlin/README.md">dust-embeddings-kotlin</a> ·
<a href="../dust-serve-kotlin/README.md">dust-serve-kotlin</a>
<br>
<a href="../dust-core-swift/README.md">dust-core-swift</a> ·
<a href="../dust-llm-swift/README.md">dust-llm-swift</a> ·
<a href="../dust-onnx-swift/README.md">dust-onnx-swift</a> ·
<a href="../dust-embeddings-swift/README.md">dust-embeddings-swift</a> ·
<strong>dust-serve-swift</strong>
</p>

---

# dust-serve-swift

Standalone model-server business logic for iOS and macOS — download management, session lifecycle, and memory-pressure eviction.

**Version: 0.1.0**

## Overview

Implements the server-side model management that sits between [DustCore](https://github.com/rogelioRuiz/dust-core-swift) contracts and a host app. Handles background downloads with SHA-256 verification, session caching with reference counting, LRU eviction under memory pressure, WiFi-only network policy enforcement, and disk space validation.

```
dust-serve-swift/
├── Package.swift                              # SPM: product "DustServe", iOS 16+ / macOS 13+
├── DustServe.podspec                    # CocoaPods spec (dep: DustCore)
├── VERSION                                    # Single source of truth for version string
├── Sources/DustServe/
│   ├── ModelRegistry.swift                    # Thread-safe descriptor store (NSLock)
│   ├── ModelStateStore.swift                  # Mutable state tracking (status, refCount, filePath)
│   ├── SessionManager.swift                   # Session lifecycle, caching, LRU eviction
│   ├── ModelSessionFactory.swift              # Protocol + stub factory
│   ├── DownloadManager.swift                  # Download orchestrator (SHA-256, progress, disk checks)
│   ├── BackgroundDownloadEngine.swift         # URLSession background download delegate
│   ├── DownloadDataSource.swift               # Protocol for download backends + DiskSpaceProvider
│   ├── URLSessionDownloadDataSource.swift     # URLSession.bytes() streaming implementation
│   ├── NetworkPolicyProvider.swift            # WiFi-only policy enforcement (NWPathMonitor)
│   └── DustCoreErrorExtensions.swift            # Error-to-dictionary serialization
└── Tests/DustServeTests/
    ├── ModelServerRegistryTests.swift         # 8 tests
    ├── SessionManagerTests.swift              # 17 tests
    ├── DownloadManagerTests.swift             # 12 tests
    ├── MockDownloadDataSource.swift           # Mock data source + disk/network providers
    └── MockModelSession.swift                 # Mock session + close order recorder
```

## Install

### Swift Package Manager — local

```swift
// Package.swift
dependencies: [
    .package(name: "DustServe", path: "../dust-serve-swift"),
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "DustServe", package: "DustServe"),
        ]
    )
]
```

### Swift Package Manager — remote (when published)

```swift
.package(url: "https://github.com/rogelioRuiz/dust-serve-swift.git", from: "0.1.0")
```

### CocoaPods

```ruby
pod 'DustServe', '~> 0.1'
```

DustCore is pulled in transitively.

## Protocols

| Protocol | Methods | Purpose |
|----------|---------|---------|
| `DownloadDataSource` | `download(from:)`, `cancel(url:)` | Pluggable download backend |
| `ModelSessionFactory` | `makeSession(descriptor:priority:)` | Creates inference sessions |
| `NetworkPolicyProvider` | `isDownloadAllowed()` | Network constraint enforcement |
| `DiskSpaceProvider` | `availableBytes(at:)` | Storage capacity check |

## Usage

### Register model descriptors

```swift
import DustServe
import DustCore

let registry = ModelRegistry()
let descriptor = DustModelDescriptor(
    id: "phi-3",
    name: "Phi-3 Mini",
    format: .gguf,
    sizeBytes: 2_400_000_000,
    version: "1.0",
    url: "https://example.com/phi-3.gguf",
    sha256: "a1b2c3..."
)
registry.register(descriptor: descriptor)
```

### Download a model

```swift
let stateStore = ModelStateStore { modelId, status in
    print("Model \(modelId) status: \(status)")
}

let downloadManager = DownloadManager(
    dataSource: URLSessionDownloadDataSource(),
    stateStore: stateStore,
    networkPolicyProvider: SystemNetworkPolicyProvider(),
    diskSpaceProvider: SystemDiskSpaceProvider(),
    baseDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
    eventEmitter: { event, payload in
        print("\(event): \(payload)")
    }
)

downloadManager.download(descriptor)
```

Events emitted: `sizeDisclosure`, `modelProgress` (throttled to 1 MB intervals), `modelReady`, `modelFailed`.

### Load and use a session

```swift
let sessionManager = SessionManager(
    stateStore: stateStore,
    factory: myFactory  // your ModelSessionFactory implementation
)

let session = try await sessionManager.loadModel(
    descriptor: descriptor,
    priority: .interactive
)
let outputs = try await session.predict(inputs: [
    DustInputTensor(name: "input", data: [1.0, 2.0], shape: [1, 2])
])

// Release when done — refCount decrements, session stays cached
try await sessionManager.unloadModel(id: "phi-3")
```

### Handle memory pressure

```swift
// Evict idle background-priority sessions
await sessionManager.evictUnderPressure(level: .standard)

// Evict all idle sessions regardless of priority
await sessionManager.evictUnderPressure(level: .critical)
```

### Error handling

```swift
do {
    let session = try await sessionManager.loadModel(
        descriptor: descriptor, priority: .interactive
    )
} catch DustCoreError.modelNotFound {
    // Descriptor not registered in state store
} catch DustCoreError.modelNotReady {
    // Model not yet downloaded / still downloading
} catch DustCoreError.networkPolicyBlocked {
    // WiFi-only policy active and on cellular
} catch DustCoreError.storageFull(let detail) {
    print("Not enough disk space: \(detail ?? "")")
} catch DustCoreError.verificationFailed(let detail) {
    print("SHA-256 mismatch: \(detail ?? "")")
}
```

## Classes

| Class | Thread Safety | Purpose |
|-------|--------------|---------|
| `ModelRegistry` | `NSLock` | Write-once descriptor store |
| `ModelStateStore` | `NSLock` | Mutable status/refCount tracking with change callbacks |
| `SessionManager` | `NSLock` + `DispatchQueue` | Session cache with ref counting and LRU eviction |
| `DownloadManager` | `NSLock` | Download orchestration, SHA-256 verification, progress events |
| `BackgroundDownloadEngine` | `NSLock` | `URLSession` background download delegate with resume data |
| `URLSessionDownloadDataSource` | `NSLock` | Streaming `URLSession.bytes()` download |
| `SystemNetworkPolicyProvider` | `NSLock` + `NWPathMonitor` | WiFi-only enforcement via UserDefaults key |
| `SystemDiskSpaceProvider` | (stateless) | Volume capacity query |

## Value types

| Type | Kind | Fields |
|------|------|--------|
| `ModelState` | struct | `status`, `filePath?`, `refCount` |
| `DownloadPreflightInfo` | struct | `contentLength?` |
| `DownloadChunk` | struct | `data`, `totalBytesReceived` |
| `MemoryPressureLevel` | enum | `.standard`, `.critical` |

## Thread safety

Each component uses an independent `NSLock` — descriptor reads never block during active downloads, and state writes never contend with session caching. `SessionManager` additionally serializes inference calls through a dedicated `DispatchQueue`. All public classes are marked `@unchecked Sendable`.

## Test

```bash
cd dust-serve-swift
swift test    # 37 XCTest tests (8 registry + 17 session + 12 download)
```

Requires macOS with Swift toolchain. Depends on `dust-core-swift` at `../dust-core-swift`. No Xcode project needed — runs via SPM.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, coding conventions, and PR guidelines.

## License

Copyright 2026 Rogelio Ruiz Perez. Licensed under the [Apache License 2.0](LICENSE).
