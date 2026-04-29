import types.{type Config, type Error, type Event, type Subscription}
import internal/manager

pub type Connection =
  manager.Connection

/// Connect to Twitch EventSub WebSocket and start listening for events.
///
/// The connection manager handles:
/// - Automatic reconnect with exponential backoff
/// - Keepalive timeout monitoring
/// - Subscription persistence across reconnects
///
/// Returns a Connection handle that can be passed to `subscribe` and `disconnect`.
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

/// Disconnect from Twitch EventSub and clean up resources.
pub fn disconnect(connection: Connection) -> Nil {
  manager.stop(connection)
}
