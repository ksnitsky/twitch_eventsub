import stratus.{type CloseReason}
import types.{type Event}

/// Messages sent from the WebSocket actor to the manager actor.
pub type WsToManagerMsg {
  /// WebSocket connected and received session_welcome.
  WsConnected(session_id: String, keepalive_seconds: Int)
  /// Received a session_keepalive message.
  WsKeepalive
  /// Received a session_reconnect message.
  WsReconnect(url: String)
  /// Received a notification event.
  WsEvent(Event)
  /// WebSocket connection closed.
  WsClosed(CloseReason)
}
