# twitch_eventsub

A robust Twitch EventSub WebSocket client library for Gleam.

Handles connection management, automatic reconnects with exponential backoff, keepalive monitoring, and subscription persistence — so you can focus on building your Twitch bot or integration.

## Features

- **EventSub WebSocket** — Connects to Twitch's modern real-time event API
- **Auto-reconnect** — Handles `session_reconnect` and unexpected disconnects with exponential backoff (max 60s)
- **Keepalive monitoring** — Detects stale connections and forces reconnect
- **Subscription persistence** — Re-subscribes to all events after reconnects
- **Type-safe** — Fully typed Gleam with exhaustive error handling
- **Extensible** — Parse any EventSub event via the `Other` variant

## Requirements

- **Erlang target only.** This library targets Erlang/BEAM and does not
  compile to JavaScript — it depends on `gleam_otp` (actors), `gleam_erlang`
  (processes/timers), `stratus` (Erlang WebSocket client), and `gleam_httpc`,
  none of which support the JS target.
- **Erlang/OTP ≥ 27** — `gleam_json` v3 uses the built-in `json` module
  introduced in OTP 27. On OTP 26 or older, `gleam_json` must be pinned
  to v1.x, which this library does not support.
- **Gleam ≥ 1.16**.

## Installation

```sh
gleam add twitch_eventsub
```

## Quick Start

```gleam
import twitch_eventsub
import types

pub fn main() {
  let config = types.Config(
    client_id: "your-client-id",
    access_token: "your-access-token",
    eventsub_ws_url: option.None,
    helix_base_url: option.None,
    on_status: option.None,
  )

  let handler = fn(event) {
    case event {
      types.Message(msg) -> {
        io.println(
          msg.chatter_user_login <> ": " <> msg.message.text
        )
      }
      _ -> Nil
    }
  }

  let assert Ok(conn) = twitch_eventsub.connect(config, handler)

  let sub = types.Subscription(
    type_: "channel.chat.message",
    version: "1",
    condition: [
      #("broadcaster_user_id", "123456"),
      #("user_id", "789012"),
    ],
  )

  let assert Ok(_) = twitch_eventsub.subscribe(conn, sub)

  // Run forever (or until disconnect)
  process.sleep_forever()
}
```

## Getting Access Tokens

### For Testing (Quick)

Use [Twitch Token Generator](https://twitchtokengenerator.com/) to get a User Access Token with the required scopes.

### For Production

Implement the [OAuth Authorization Code flow](https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/):

1. Redirect user to: `https://id.twitch.tv/oauth2/authorize?client_id=XXX&redirect_uri=YYY&response_type=code&scope=user:read:chat+channel:bot`
2. Exchange code for tokens via `POST /oauth2/token`

## API Reference

### Connection

```gleam
/// Connect to Twitch EventSub and start listening for events.
/// Waits for session_welcome before returning (up to 5 seconds).
pub fn connect(
  config: Config,
  handler: fn(Event) -> Nil,
) -> Result(Connection, Error)

/// Subscribe to an EventSub event type. Subscriptions are tracked by the
/// manager and re-created automatically after a reconnect.
pub fn subscribe(
  connection: Connection,
  subscription: Subscription,
) -> Result(Nil, Error)

/// Remove all subscriptions of the given EventSub type. Returns
/// `Error(SubscriptionNotFound)` if there is no matching subscription.
pub fn unsubscribe(
  connection: Connection,
  subscription_type: String,
) -> Result(Nil, Error)

/// Subscriptions currently tracked by the manager (its local view, not a
/// round-trip to Twitch).
pub fn list_subscriptions(connection: Connection) -> List(Subscription)

/// Disconnect from Twitch EventSub and clean up resources.
pub fn disconnect(connection: Connection) -> Nil
```

#### Convenience helpers

Pre-built builders for the two most common subscriptions:

```gleam
/// Equivalent to subscribing to "channel.chat.message" v1 with
/// {broadcaster_user_id, user_id} as the condition.
pub fn subscribe_chat(
  connection: Connection,
  broadcaster_user_id: String,
  user_id: String,
) -> Result(Nil, Error)

/// Equivalent to subscribing to "channel.follow" v2. `moderator_user_id`
/// must be a moderator-or-broadcaster on the target channel.
pub fn subscribe_follows(
  connection: Connection,
  broadcaster_user_id: String,
  moderator_user_id: String,
) -> Result(Nil, Error)
```

### Types

```gleam
/// Configuration for connecting to Twitch EventSub.
pub type Config {
  Config(
    client_id: String,
    access_token: String,
    /// Optional override for the EventSub WebSocket URL.
    /// Defaults to "wss://eventsub.wss.twitch.tv/ws" when None.
    eventsub_ws_url: Option(String),
    /// Optional override for the Helix base URL.
    /// Defaults to "https://api.twitch.tv" when None.
    helix_base_url: Option(String),
    /// Optional callback for connection-lifecycle and recovery events
    /// (reconnects, keepalive timeouts, resubscribe failures). The library
    /// does no logging of its own — wire this to your logging stack if
    /// you want visibility.
    on_status: Option(fn(StatusEvent) -> Nil),
  )
}

/// Subscription request for EventSub.
pub type Subscription {
  Subscription(
    type_: String,       // e.g. "channel.chat.message"
    version: String,     // e.g. "1"
    condition: List(#(String, String)),
  )
}

/// Parsed EventSub notification event.
pub type Event {
  Message(ChatMessage)
  Other(type_: String, payload: Dynamic)
}
```

### Chat Message Structure

`ChatMessage` mirrors the full Twitch `channel.chat.message` event. Nullable
fields come through as `Option`; non-nullable but possibly empty fields
(`color`, `badges`) come through as plain values.

```gleam
pub type ChatMessage {
  ChatMessage(
    broadcaster_user_id: String,
    broadcaster_user_login: String,
    broadcaster_user_name: String,
    chatter_user_id: String,
    chatter_user_login: String,
    chatter_user_name: String,
    message_id: String,
    message_type: String,   // "text", "channel_points_highlighted", ...
    message: MessageContent,
    color: String,          // hex like "#FF0000", may be empty
    badges: List(Badge),
    cheer: Option(Cheer),
    reply: Option(Reply),
    channel_points_custom_reward_id: Option(String),
    // Shared chat: set when the message was re-broadcast from another channel
    source_broadcaster_user_id: Option(String),
    source_broadcaster_user_login: Option(String),
    source_broadcaster_user_name: Option(String),
    source_message_id: Option(String),
    source_badges: Option(List(Badge)),
  )
}

pub type Badge {
  Badge(set_id: String, id: String, info: String)
}

pub type Cheer { Cheer(bits: Int) }

pub type Reply {
  Reply(
    parent_message_id: String,
    parent_message_body: String,
    parent_user_id: String,
    parent_user_login: String,
    parent_user_name: String,
    thread_message_id: String,
    thread_user_id: String,
    thread_user_login: String,
    thread_user_name: String,
  )
}

pub type MessageContent {
  MessageContent(
    text: String,
    fragments: List(MessageFragment),
  )
}

pub type MessageFragment {
  Text(text: String)
  Emote(text: String, id: String, set_id: String, owner_id: String, format: List(String))
  Mention(text: String, user_id: String, user_login: String, user_name: String)
  Cheermote(text: String, prefix: String, bits: Int, tier: Int)
}
```

#### Filtering by badge

Common badge `set_id` values: `broadcaster`, `moderator`, `vip`, `subscriber`
(tier in `info`), `premium`, `turbo`, `staff`, `admin`, `partner`, `bits`.
Channels can register a chat bot via the Helix `Add Channel Chat Bot`
endpoint, and that bot's messages then come through with a dedicated badge —
filter by the corresponding `set_id` if you want to ignore bot traffic:

```gleam
import gleam/list
let is_bot = list.any(msg.badges, fn(b) { b.set_id == "bot-badge" })
```

(The exact `set_id` for the chat-bot indicator isn't documented by Twitch;
print `msg.badges` from a real bot message in your channel to confirm.)

## Advanced Usage

### Handling Multiple Event Types

```gleam
let handler = fn(event) {
  case event {
    types.Message(msg) -> handle_chat(msg)
    types.Other("channel.follow", payload) -> handle_follow(payload)
    types.Other(type_, _) -> io.println("Unhandled: " <> type_)
  }
}
```

### Graceful Shutdown

```gleam
// Disconnect and clean up resources
twitch_eventsub.disconnect(conn)
```

### Error Handling

```gleam
case twitch_eventsub.connect(config, handler) {
  Ok(conn) -> {
    // Use connection...
  }
  Error(types.WebSocketError(reason)) -> {
    io.println("Connection failed: " <> reason)
  }
  Error(types.MaxReconnectAttemptsExceeded) -> {
    io.println("Too many reconnect attempts")
  }
}
```

### Custom Endpoints (twitch-cli, tests)

Both `eventsub_ws_url` and `helix_base_url` are optional and default to
Twitch's public endpoints. Override them to point at a local
[twitch-cli](https://github.com/twitchdev/twitch-cli) mock server (for
example, `twitch event websocket start-server` plus `twitch mock-api start`),
or at any HTTP/WS server in tests:

```gleam
types.Config(
  client_id: "stub",
  access_token: "stub",
  eventsub_ws_url: option.Some("ws://localhost:8080/ws"),
  helix_base_url: option.Some("http://localhost:8080"),
  on_status: option.None,
)
```

### Observability

The library does no logging of its own. Set `on_status` to receive
connection-lifecycle and recovery events (reconnects, keepalive timeouts,
resubscribe failures) and route them to your logging stack:

```gleam
let on_status = fn(event) {
  case event {
    types.KeepaliveTimedOut -> io.println("ws stalled, reconnecting")
    types.ReconnectsExhausted -> io.println("giving up")
    types.ResubscribeFailed(type_, _) ->
      io.println("could not resubscribe " <> type_)
    _ -> Nil
  }
}

let config = types.Config(
  client_id: "...",
  access_token: "...",
  eventsub_ws_url: option.None,
  helix_base_url: option.None,
  on_status: option.Some(on_status),
)
```

See `StatusEvent` in `types.gleam` for the full list of variants.

## Required OAuth Scopes

The token used in `Config.access_token` must be a **user access token** for
the user named in the subscription `condition` (`user_id` for chat,
`moderator_user_id` for follows, etc.) and must carry the matching scope:

| Event Type | Token owner | Required Scope |
|---|---|---|
| `channel.chat.message` | the user reading chat | `user:read:chat` |
| `channel.follow` (v2) | a moderator-or-broadcaster on the channel | `moderator:read:followers` |
| `channel.subscribe` | the broadcaster | `channel:read:subscriptions` |

For `channel.chat.message` the broadcaster does **not** need to authorize
your app — chat is public, anyone with a `user:read:chat` token can listen
to any channel (a streamer can still ban your bot account from their chat
afterwards).

See [Twitch EventSub Reference](https://dev.twitch.tv/docs/eventsub/eventsub-subscription-types/) for the full per-event scope list.

## Supported Event Types

### Built-in Parsing
- `channel.chat.message` — Chat messages with user info and text content

### Extensible
Any EventSub event type can be received via the `types.Other(type_, payload)` variant. The raw `Dynamic` payload can be decoded as needed.

## Architecture

```
User Code
    ↓
twitch_eventsub.gleam  (public API: connect, subscribe, disconnect)
    ↓
internal/manager.gleam  (OTP actor: reconnect, keepalive, subscriptions)
    ↓
internal/websocket.gleam  (stratus WebSocket actor)
    ↓
Twitch EventSub WebSocket
```

## Error Handling

The library handles these error scenarios:

- **WebSocket handshake failure** — Retries with exponential backoff
- **Unexpected disconnect** — Retries up to 10 times with backoff (1s, 2s, 4s... max 60s)
- **Keepalive timeout** — Forces reconnect if no keepalive received within timeout + 2s grace
- **Subscription failure** — Returns error immediately (no retry)
- **Max reconnect exceeded** — Stops the actor gracefully

## License

Apache-2.0
