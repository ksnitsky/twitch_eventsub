import gleam/option.{type Option, None, Some}
import internal/manager
import types.{
  type ChatMessage, type Config as TypesConfig, type Error as TypesError,
  type Event as TypesEvent, type Subscription as TypesSubscription, Config,
  Message, Subscription,
}

pub type Connection =
  manager.Connection

pub type Config =
  TypesConfig

pub type Error =
  TypesError

pub type Event =
  TypesEvent

pub type Subscription =
  TypesSubscription

/// Create a new Config for connecting to Twitch EventSub.
pub fn new_config(
  client_id client_id: String,
  access_token access_token: String,
  eventsub_ws_url eventsub_ws_url: Option(String),
  helix_base_url helix_base_url: Option(String),
  on_status on_status: Option(fn(types.StatusEvent) -> Nil),
) -> Config {
  Config(
    client_id: client_id,
    access_token: access_token,
    eventsub_ws_url: eventsub_ws_url,
    helix_base_url: helix_base_url,
    on_status: on_status,
  )
}

/// Extract ChatMessage from an Event if it's a Message event.
pub fn event_chat_message(event: Event) -> Option(ChatMessage) {
  case event {
    Message(msg) -> Some(msg)
    _ -> None
  }
}

/// Connect to Twitch EventSub WebSocket and start listening for events.
///
/// The connection manager handles:
/// - Automatic reconnect with exponential backoff
/// - Keepalive timeout monitoring
/// - Subscription persistence across reconnects
///
/// Returns a Connection handle that can be passed to `subscribe`,
/// `unsubscribe`, `list_subscriptions`, and `disconnect`.
pub fn connect(
  config: Config,
  handler: fn(Event) -> Nil,
) -> Result(Connection, Error) {
  manager.start(config, handler)
}

/// Subscribe to an EventSub event type.
///
/// Requires a valid session (established after `connect`).
/// Subscriptions are automatically re-created after reconnects.
pub fn subscribe(
  connection: Connection,
  subscription: Subscription,
) -> Result(Nil, Error) {
  manager.subscribe(connection, subscription)
}

/// Remove all subscriptions of the given EventSub type. Returns
/// `SubscriptionNotFound` if there is no matching subscription.
pub fn unsubscribe(
  connection: Connection,
  subscription_type: String,
) -> Result(Nil, Error) {
  manager.unsubscribe(connection, subscription_type)
}

/// List subscriptions currently tracked by the manager.
///
/// This is the manager's local view; it reflects subscriptions registered
/// through this connection rather than what Twitch has stored server-side.
pub fn list_subscriptions(connection: Connection) -> List(Subscription) {
  manager.list_subscriptions(connection)
}

/// Convenience: subscribe to chat messages in `broadcaster_user_id`'s channel
/// as user `user_id`. Equivalent to building a `channel.chat.message` v1
/// subscription manually.
pub fn subscribe_chat(
  connection: Connection,
  broadcaster_user_id: String,
  user_id: String,
) -> Result(Nil, Error) {
  let sub =
    Subscription(type_: "channel.chat.message", version: "1", condition: [
      #("broadcaster_user_id", broadcaster_user_id),
      #("user_id", user_id),
    ])
  subscribe(connection, sub)
}

/// Convenience: subscribe to follow events for `broadcaster_user_id`. The
/// follow EventSub topic requires a moderator-or-broadcaster `moderator_user_id`,
/// so it must be passed explicitly (it is not always equal to `broadcaster_user_id`).
pub fn subscribe_follows(
  connection: Connection,
  broadcaster_user_id: String,
  moderator_user_id: String,
) -> Result(Nil, Error) {
  let sub =
    Subscription(type_: "channel.follow", version: "2", condition: [
      #("broadcaster_user_id", broadcaster_user_id),
      #("moderator_user_id", moderator_user_id),
    ])
  subscribe(connection, sub)
}

/// Disconnect from Twitch EventSub and clean up resources.
pub fn disconnect(connection: Connection) -> Nil {
  manager.stop(connection)
}
