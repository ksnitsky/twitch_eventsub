import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import internal/decoders
import types.{
  type Config, type Error, type Subscription, AuthError, HttpError,
  InvalidMessage, SubscriptionError,
}

const default_helix_base_url = "https://api.twitch.tv"

const helix_subscriptions_path = "/helix/eventsub/subscriptions"

/// Create an EventSub subscription via the Helix API.
///
/// Returns the Twitch-assigned subscription ID on success, which the manager
/// uses to address the subscription later (e.g. for unsubscribe).
pub fn create(
  config: Config,
  session_id: String,
  subscription: Subscription,
) -> Result(String, Error) {
  let body = build_subscription_body(subscription, session_id)

  let req =
    helix_request(config)
    |> request.set_method(http.Post)
    |> request.set_header("Content-Type", "application/json")
    |> request.set_body(body)

  use resp <- result.try(send(req))

  case resp.status {
    202 | 201 -> parse_first_subscription_id(resp.body)
    _ -> Error(status_to_error(resp.status, resp.body))
  }
}

/// Delete an existing EventSub subscription by its Twitch-assigned ID.
pub fn delete(config: Config, subscription_id: String) -> Result(Nil, Error) {
  let req =
    helix_request(config)
    |> request.set_method(http.Delete)
    |> request.set_query([#("id", subscription_id)])

  use resp <- result.try(send(req))

  case resp.status {
    204 -> Ok(Nil)
    _ -> Error(status_to_error(resp.status, resp.body))
  }
}

/// List the IDs of subscriptions associated with the current app token.
///
/// Twitch paginates this endpoint; we only fetch the first page since the
/// manager uses this primarily to reconcile state, not as the source of truth.
pub fn list(config: Config) -> Result(List(String), Error) {
  let req =
    helix_request(config)
    |> request.set_method(http.Get)

  use resp <- result.try(send(req))

  case resp.status {
    200 -> parse_subscription_ids(resp.body)
    _ -> Error(status_to_error(resp.status, resp.body))
  }
}

// --- Body building ---

pub fn build_subscription_body(
  subscription: Subscription,
  session_id: String,
) -> String {
  let condition_object =
    subscription.condition
    |> list.map(fn(pair) {
      let #(key, value) = pair
      #(key, json.string(value))
    })

  json.object([
    #("type", json.string(subscription.type_)),
    #("version", json.string(subscription.version)),
    #("condition", json.object(condition_object)),
    #(
      "transport",
      json.object([
        #("method", json.string("websocket")),
        #("session_id", json.string(session_id)),
      ]),
    ),
  ])
  |> json.to_string()
}

// --- Internal helpers ---

fn helix_request(config: Config) -> Request(String) {
  let base = option.unwrap(config.helix_base_url, default_helix_base_url)
  let #(scheme, host, port) = parse_base_url(base)

  let req =
    request.new()
    |> request.set_scheme(scheme)
    |> request.set_host(host)
    |> request.set_path(helix_subscriptions_path)
    |> request.set_header("Client-Id", config.client_id)
    |> request.set_header("Authorization", "Bearer " <> config.access_token)
    |> request.set_body("")

  case port {
    Some(p) -> request.set_port(req, p)
    None -> req
  }
}

fn parse_base_url(base: String) -> #(http.Scheme, String, option.Option(Int)) {
  case uri.parse(base) {
    Ok(parsed) -> {
      let scheme = case parsed.scheme {
        Some("https") -> http.Https
        Some("http") -> http.Http
        _ -> http.Https
      }
      let host = option.unwrap(parsed.host, "api.twitch.tv")
      #(scheme, host, parsed.port)
    }
    Error(_) -> #(http.Https, "api.twitch.tv", None)
  }
}

fn send(req: Request(String)) -> Result(Response(String), Error) {
  httpc.send(req)
  |> result.map_error(fn(err) {
    HttpError("HTTP request failed: " <> string.inspect(err))
  })
}

/// Map Twitch Helix error responses to a typed `Error`. 401/403 become
/// `AuthError` so callers can stop retrying and surface a useful message
/// instead of treating it as a transient subscription failure.
pub fn status_to_error(status: Int, body: String) -> Error {
  case status {
    401 | 403 ->
      AuthError(
        "Twitch returned "
        <> string.inspect(status)
        <> " (token missing/expired/insufficient scope): "
        <> body,
      )
    _ ->
      SubscriptionError(
        "Subscription request failed with status "
        <> string.inspect(status)
        <> ": "
        <> body,
      )
  }
}

/// Parse the subscription ID from Twitch's `POST /eventsub/subscriptions`
/// response. The response wraps the created subscription in a `data` array;
/// we want the first (and only) entry's `id`.
pub fn parse_first_subscription_id(body: String) -> Result(String, Error) {
  use ids <- result.try(parse_subscription_ids(body))
  case ids {
    [id, ..] -> Ok(id)
    [] ->
      Error(InvalidMessage(
        "Twitch subscription response did not include any data entries",
      ))
  }
}

/// Parse the list of subscription IDs from a Helix list response.
pub fn parse_subscription_ids(body: String) -> Result(List(String), Error) {
  let decoder =
    decode.field(
      "data",
      decode.list(decoders.subscription_id()),
      decode.success,
    )
  json.parse(body, decoder)
  |> result.map_error(fn(err) {
    InvalidMessage(
      "Failed to parse Twitch subscription response: " <> string.inspect(err),
    )
  })
}
