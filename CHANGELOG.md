# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-01

### Added

- Initial release of `twitch_eventsub`
- EventSub WebSocket client for Twitch
- Automatic reconnect with exponential backoff (1s → 60s max, 10 attempts)
- Keepalive timeout monitoring (resets on any incoming message, not only
  `session_keepalive`)
- Subscription persistence across reconnects
- Configurable EventSub WebSocket and Helix URLs (for tests / twitch-cli)
- `on_status` callback for connection-lifecycle observability
- Convenience helpers `subscribe_chat` and `subscribe_follows`
- Full parsing of `channel.chat.message` events: `broadcaster_user_name`,
  `chatter_user_name`, `message_id`, `message_type`, `color`, `badges`,
  `cheer`, `reply`, `channel_points_custom_reward_id`, and shared-chat
  `source_*` fields. Supporting types: `Badge`, `Cheer`, `Reply`.
- `MessageFragment` fidelity: `Mention.user_name`, `Emote.owner_id`,
  `Emote.format`.
- Extensible event handling via `Other` variant for any EventSub type
- Type-safe error handling with custom error types
- Graceful shutdown support

[0.1.0]: https://github.com/ksnitsky/twitch_eventsub/releases/tag/v0.1.0
