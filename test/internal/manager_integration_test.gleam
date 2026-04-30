import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import support/mock_servers.{type WsEvent, WsConnected, WsDisconnected}
import twitch_eventsub
import types.{type Config, type Event, Config, Message}

const sample_session_id = "session-1"

const broadcaster_id = "111"

const chatter_id = "222"

fn config_for(helix_port: Int, ws_port: Int) -> Config {
  Config(
    client_id: "stub-client",
    access_token: "stub-token",
    eventsub_ws_url: Some("ws://127.0.0.1:" <> int.to_string(ws_port) <> "/ws"),
    helix_base_url: Some("http://127.0.0.1:" <> int.to_string(helix_port)),
    on_status: None,
  )
}

fn noop_helix_handler() -> mock_servers.HelixHandler {
  fn(_method, _body) { #(202, "{\"data\":[{\"id\":\"sub-stub\"}]}") }
}

fn noop_handler(_event: Event) -> Nil {
  Nil
}

pub fn connect_receives_welcome_test() {
  let events = process.new_subject()
  let #(ws_port, stop_ws) =
    mock_servers.start_eventsub(
      [mock_servers.welcome_payload(sample_session_id, 30)],
      events,
    )
  let #(helix_port, stop_helix) = mock_servers.start_helix(noop_helix_handler())

  let result =
    twitch_eventsub.connect(config_for(helix_port, ws_port), noop_handler)

  case result {
    Ok(conn) -> twitch_eventsub.disconnect(conn)
    Error(_) -> Nil
  }
  stop_ws()
  stop_helix()

  result
  |> should.be_ok
  Nil
}

pub fn subscribe_creates_helix_request_test() {
  let body_subject = process.new_subject()
  let helix_handler = fn(method, body) {
    case method {
      http.Post -> {
        process.send(body_subject, body)
        #(202, "{\"data\":[{\"id\":\"sub-abc\"}]}")
      }
      _ -> #(405, "")
    }
  }

  let events = process.new_subject()
  let #(ws_port, stop_ws) =
    mock_servers.start_eventsub(
      [mock_servers.welcome_payload(sample_session_id, 30)],
      events,
    )
  let #(helix_port, stop_helix) = mock_servers.start_helix(helix_handler)

  let assert Ok(conn) =
    twitch_eventsub.connect(config_for(helix_port, ws_port), noop_handler)

  let sub_result =
    twitch_eventsub.subscribe_chat(conn, broadcaster_id, chatter_id)

  let received_body = process.receive(body_subject, 2000)

  twitch_eventsub.disconnect(conn)
  stop_ws()
  stop_helix()

  sub_result
  |> should.be_ok

  received_body
  |> should.be_ok
}

pub fn notification_invokes_handler_test() {
  let event_subject = process.new_subject()
  let handler = fn(event) {
    process.send(event_subject, event)
    Nil
  }

  let events = process.new_subject()
  let #(ws_port, stop_ws) =
    mock_servers.start_eventsub(
      [
        mock_servers.welcome_payload(sample_session_id, 30),
        mock_servers.chat_notification_payload(
          broadcaster_user_id: broadcaster_id,
          chatter_user_id: chatter_id,
          text: "hello",
        ),
      ],
      events,
    )
  let #(helix_port, stop_helix) = mock_servers.start_helix(noop_helix_handler())

  let assert Ok(conn) =
    twitch_eventsub.connect(config_for(helix_port, ws_port), handler)

  let received = process.receive(event_subject, 2000)

  twitch_eventsub.disconnect(conn)
  stop_ws()
  stop_helix()

  case received {
    Ok(Message(msg)) -> {
      msg.message.text
      |> should.equal("hello")
      Nil
    }
    _ -> panic as "Expected a chat Message event"
  }
}

pub fn session_reconnect_switches_url_test() {
  let helix_calls = process.new_subject()
  let helix_handler = fn(method, _body) {
    case method {
      http.Post -> {
        process.send(helix_calls, Nil)
        #(202, "{\"data\":[{\"id\":\"sub-stub\"}]}")
      }
      _ -> #(405, "")
    }
  }
  let #(helix_port, stop_helix) = mock_servers.start_helix(helix_handler)

  // Start mock #2 first so we can plumb its URL into mock #1's reconnect frame.
  let events_2 = process.new_subject()
  let #(ws_port_2, stop_ws_2) =
    mock_servers.start_eventsub(
      [mock_servers.welcome_payload("session-2", 30)],
      events_2,
    )

  let mock2_url = "ws://127.0.0.1:" <> int.to_string(ws_port_2) <> "/ws"
  let events_1 = process.new_subject()
  let #(ws_port_1, stop_ws_1) =
    mock_servers.start_eventsub(
      [
        mock_servers.welcome_payload(sample_session_id, 30),
        mock_servers.reconnect_payload(mock2_url),
      ],
      events_1,
    )

  let assert Ok(conn) =
    twitch_eventsub.connect(config_for(helix_port, ws_port_1), noop_handler)

  let assert Ok(_) =
    twitch_eventsub.subscribe_chat(conn, broadcaster_id, chatter_id)

  // Wait for the second WS mock to register a connection (the reconnect).
  let connected_2 = process.receive(events_2, 3000)
  // The manager should resubscribe through Helix after reconnecting; wait for
  // the second POST to confirm.
  let _first_call = process.receive(helix_calls, 1000)
  let resub_call = process.receive(helix_calls, 3000)

  twitch_eventsub.disconnect(conn)
  stop_ws_1()
  stop_ws_2()
  stop_helix()

  case connected_2 {
    Ok(WsConnected) -> Nil
    _ -> panic as "Expected mock #2 to receive a connection after reconnect"
  }

  resub_call
  |> should.be_ok
}

pub fn keepalive_timeout_triggers_reconnect_test() {
  let events = process.new_subject()
  let #(ws_port, stop_ws) =
    mock_servers.start_eventsub(
      [mock_servers.welcome_payload(sample_session_id, 1)],
      events,
    )
  let #(helix_port, stop_helix) = mock_servers.start_helix(noop_helix_handler())

  let assert Ok(conn) =
    twitch_eventsub.connect(config_for(helix_port, ws_port), noop_handler)

  // First WsConnected from the initial connect.
  let _initial = process.receive(events, 1000)
  // After the keepalive timer expires (1s) plus 2s grace plus ~1s reconnect
  // backoff, the manager should reconnect to the same URL — the mock should
  // see a second WsConnected event.
  let second_connect = drain_until_connected(events, 6000)

  twitch_eventsub.disconnect(conn)
  stop_ws()
  stop_helix()

  second_connect
  |> should.be_true
}

pub fn disconnect_cleans_up_test() {
  let events = process.new_subject()
  let #(ws_port, stop_ws) =
    mock_servers.start_eventsub(
      [mock_servers.welcome_payload(sample_session_id, 30)],
      events,
    )
  let #(helix_port, stop_helix) = mock_servers.start_helix(noop_helix_handler())

  let assert Ok(conn) =
    twitch_eventsub.connect(config_for(helix_port, ws_port), noop_handler)

  twitch_eventsub.disconnect(conn)

  let saw_disconnect = drain_until_disconnected(events, 2000)

  stop_ws()
  stop_helix()

  saw_disconnect
  |> should.be_true
}

// --- Helpers ---

fn drain_until_connected(
  subject: process.Subject(WsEvent),
  timeout: Int,
) -> Bool {
  case process.receive(subject, timeout) {
    Ok(WsConnected) -> True
    Ok(_) -> drain_until_connected(subject, timeout)
    Error(_) -> False
  }
}

fn drain_until_disconnected(
  subject: process.Subject(WsEvent),
  timeout: Int,
) -> Bool {
  case process.receive(subject, timeout) {
    Ok(WsDisconnected) -> True
    Ok(_) -> drain_until_disconnected(subject, timeout)
    Error(_) -> False
  }
}
