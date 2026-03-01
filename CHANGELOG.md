# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-02-28

### Added

- `ModelRegistry` — thread-safe, write-once descriptor store with `NSLock`
- `ModelStateStore` — mutable state tracking (status, refCount, filePath) with change callbacks
- `SessionManager` — session caching with reference counting and LRU eviction under memory pressure
- `DownloadManager` — download orchestrator with SHA-256 verification, progress events, and disk space validation
- `BackgroundDownloadEngine` — `URLSession` background download delegate with resume data support
- `URLSessionDownloadDataSource` — streaming download via `URLSession.bytes()`
- `SystemNetworkPolicyProvider` — WiFi-only enforcement via `NWPathMonitor` + `UserDefaults`
- `SystemDiskSpaceProvider` — volume capacity queries
- `ModelSessionFactory` protocol + `StubModelSessionFactory`
- `DownloadDataSource` / `DiskSpaceProvider` / `NetworkPolicyProvider` protocols
- `ModelState`, `DownloadChunk`, `DownloadPreflightInfo` value types
- `MemoryPressureLevel` enum (`.standard`, `.critical`)
- `DustCoreError` dictionary serialization
- Stale `.part` file cleanup on launch
- 37 XCTest tests (8 registry + 17 session + 12 download)
