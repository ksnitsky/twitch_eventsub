# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2024-04-29

### Added

- Initial release of `gwitchel`
- EventSub WebSocket client for Twitch
- Automatic reconnect with exponential backoff (1s → 60s max, 10 attempts)
- Keepalive timeout monitoring
- Subscription persistence across reconnects
- Built-in parsing for `channel.chat.message` events
- Extensible event handling via `Other` variant for any EventSub type
- Type-safe error handling with custom error types
- Graceful shutdown support

[0.1.0]: https://github.com/ksnitsky/gwitchel/releases/tag/v0.1.0
