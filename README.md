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

/// Subscribe to an EventSub event type.
pub fn subscribe(
  connection: Connection,
  subscription: Subscription,
) -> Result(Nil, Error)

/// Disconnect from Twitch EventSub and clean up resources.
pub fn disconnect(connection: Connection) -> Nil
```

### Types

```gleam
/// Configuration for connecting to Twitch EventSub.
pub type Config {
  Config(
    client_id: String,
    access_token: String,
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

```gleam
pub type ChatMessage {
  ChatMessage(
    broadcaster_user_id: String,
    broadcaster_user_login: String,
    chatter_user_id: String,
    chatter_user_login: String,
    message: MessageContent,
  )
}

pub type MessageContent {
  MessageContent(
    text: String,
    fragments: List(MessageFragment),
  )
}
```

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

## Required OAuth Scopes

| Event Type | Required Scope |
|---|---|
| `channel.chat.message` | `user:read:chat` + `channel:bot` (broadcaster must authorize) |
| `channel.follow` | `moderator:read:followers` |
| `channel.subscribe` | `channel:read:subscriptions` |

See [Twitch EventSub Reference](https://dev.twitch.tv/docs/eventsub/eventsub-subscription-types/) for full details.

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
