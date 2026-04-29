import gleam/dynamic.{type Dynamic}

/// Configuration for connecting to Twitch EventSub.
pub type Config {
  Config(
    /// Twitch application client ID.
    client_id: String,
    /// Twitch app access token (or user access token for the bot).
    access_token: String,
  )
}

/// Represents a parsed EventSub notification event.
pub type Event {
  /// A chat message was sent in a channel.
  Message(ChatMessage)
  /// Any other EventSub event type (raw JSON for extensibility).
  Other(type_: String, payload: Dynamic)
}

/// Parsed chat message from `channel.chat.message`.
pub type ChatMessage {
  ChatMessage(
    broadcaster_user_id: String,
    broadcaster_user_login: String,
    chatter_user_id: String,
    chatter_user_login: String,
    message: MessageContent,
  )
}

/// Content of a chat message.
pub type MessageContent {
  MessageContent(
    text: String,
    /// Fragments can be used for advanced parsing (emotes, mentions, etc.)
    fragments: List(MessageFragment),
  )
}

/// A single fragment of a chat message.
pub type MessageFragment {
  Text(String)
  // TODO: add Emote, Mention, etc. when needed
}

/// Errors that can occur when using gwitchel.
pub type Error {
  /// Failed to establish WebSocket connection.
  WebSocketError(String)
  /// Failed to subscribe to an event type.
  SubscriptionError(String)
  /// Invalid or unexpected message from Twitch.
  InvalidMessage(String)
  /// Session was closed unexpectedly.
  SessionClosed
  /// HTTP request failed.
  HttpError(String)
  /// Maximum reconnect attempts exceeded.
  MaxReconnectAttemptsExceeded
  /// Keepalive timeout — no response from Twitch within expected window.
  KeepaliveTimeout
  /// Internal library error.
  InternalError(String)
}

/// Subscription request for EventSub.
pub type Subscription {
  Subscription(
    /// EventSub type, e.g. "channel.chat.message"
    type_: String,
    /// Version of the subscription, e.g. "1"
    version: String,
    /// Condition fields (specific to the event type).
    condition: List(#(String, String)),
  )
}
