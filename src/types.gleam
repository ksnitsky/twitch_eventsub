import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option, None, Some}

/// Configuration for connecting to Twitch EventSub.
pub type Config {
  Config(
    /// Twitch application client ID.
    client_id: String,
    /// Twitch app access token (or user access token for the bot).
    access_token: String,
    /// Override for the EventSub WebSocket URL. Defaults to
    /// "wss://eventsub.wss.twitch.tv/ws". Useful for tests and for
    /// pointing at twitch-cli (`twitch event websocket start-server`).
    eventsub_ws_url: Option(String),
    /// Override for the Helix base URL. Defaults to
    /// "https://api.twitch.tv".
    helix_base_url: Option(String),
    /// Optional callback invoked for connection lifecycle and recovery
    /// events that the library has no other channel to surface (reconnects,
    /// keepalive timeouts, resubscribe failures). Callers can wire this to
    /// their own logging stack — the library does not log internally.
    on_status: Option(fn(StatusEvent) -> Nil),
  )
}

/// Lifecycle and recovery events the manager emits for an installed
/// `on_status` callback. None of these are user-actionable on their own;
/// they exist for observability.
pub type StatusEvent {
  /// WebSocket established and Twitch sent `session_welcome`.
  Connected(session_id: String)
  /// WebSocket closed. Reconnect handling may follow depending on the
  /// reason (server-initiated `session_reconnect`, keepalive timeout,
  /// network drop).
  Disconnected(reason: String)
  /// Manager is attempting to (re)connect. `attempt` is 0 for a clean
  /// `session_reconnect`, and 1+ for backoff retries after a failure.
  Reconnecting(url: String, attempt: Int)
  /// No keepalive received within the timeout window. The manager will
  /// close the WS and reconnect.
  KeepaliveTimedOut
  /// Maximum reconnect attempts reached; the manager is stopping.
  ReconnectsExhausted
  /// `disconnect()` was called and the manager is shutting down.
  Stopping
  /// A connection or actor-start attempt failed; the manager will
  /// schedule a reconnect with backoff.
  ConnectionAttemptFailed(error: Error)
  /// Re-creating a subscription after a reconnect failed. The subscription
  /// has been dropped from the manager's tracked list.
  ResubscribeFailed(type_: String, error: Error)
  /// Failed to parse an incoming EventSub frame.
  MessageParseFailed(detail: String)
  /// Received a Twitch message whose type is not handled by the library.
  UnknownMessageType(msg_type: String)
}

/// Helper for internal modules: invoke the configured status callback if
/// present. Defined here so every module that has a `Config` can emit
/// without an extra dependency.
pub fn emit_status(config: Config, event: StatusEvent) -> Nil {
  case config.on_status {
    Some(cb) -> cb(event)
    None -> Nil
  }
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
  /// Plain text segment.
  Text(text: String)
  /// Twitch emote reference.
  Emote(text: String, id: String, set_id: String)
  /// Mention of another user (@user).
  Mention(text: String, user_id: String, user_login: String)
  /// Bits / cheermote (e.g. "Cheer100").
  Cheermote(text: String, prefix: String, bits: Int, tier: Int)
}

/// Errors that can occur when using twitch_eventsub.
pub type Error {
  /// Failed to establish WebSocket connection.
  WebSocketError(String)
  /// Failed to subscribe to an event type.
  SubscriptionError(String)
  /// Twitch returned 401/403 — the access token is missing, expired, or
  /// lacks the required scope. Not retried automatically.
  AuthError(String)
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
  /// No matching subscription was found for unsubscribe/lookup.
  SubscriptionNotFound
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
