import gleeunit/should
import types.{
  AuthError, HttpError, InvalidMessage, KeepaliveTimeout,
  MaxReconnectAttemptsExceeded, SessionClosed, SubscriptionError,
  SubscriptionNotFound, WebSocketError,
}

pub fn error_variants_distinct_test() {
  // Construct each variant to ensure they exist and remain part of the API.
  let _ = WebSocketError("x")
  let _ = SubscriptionError("x")
  let _ = AuthError("x")
  let _ = InvalidMessage("x")
  let _ = HttpError("x")
  let _ = SessionClosed
  let _ = MaxReconnectAttemptsExceeded
  let _ = KeepaliveTimeout
  let _ = SubscriptionNotFound

  should.equal(WebSocketError("a"), WebSocketError("a"))
  should.not_equal(WebSocketError("a"), WebSocketError("b"))
  should.not_equal(SessionClosed, MaxReconnectAttemptsExceeded)
}
