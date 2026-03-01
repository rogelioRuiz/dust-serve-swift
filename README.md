
# dust-serve-swift

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS_16+_|_macOS_13+-lightgrey.svg)]()

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

Copyright 2026 T6X. Licensed under the [Apache License 2.0](LICENSE).
