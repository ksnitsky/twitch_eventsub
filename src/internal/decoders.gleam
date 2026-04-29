import gleam/dynamic/decode
import types.{
  type ChatMessage, type MessageContent, type MessageFragment, Cheermote,
  ChatMessage, Emote, Mention, MessageContent, Text,
}

/// Decoder for the contents of `payload.session` in `session_welcome`.
pub fn welcome_session() -> decode.Decoder(#(String, Int)) {
  use id <- decode.field("id", decode.string)
  use keepalive <- decode.optional_field(
    "keepalive_timeout_seconds",
    10,
    decode.int,
  )
  decode.success(#(id, keepalive))
}

/// Decoder for the `reconnect_url` field inside `payload.session`.
pub fn reconnect_url() -> decode.Decoder(String) {
  use url <- decode.field("reconnect_url", decode.string)
  decode.success(url)
}

/// Decoder for `payload.event` of `channel.chat.message`.
pub fn chat_message() -> decode.Decoder(ChatMessage) {
  use broadcaster_user_id <- decode.field("broadcaster_user_id", decode.string)
  use broadcaster_user_login <- decode.field(
    "broadcaster_user_login",
    decode.string,
  )
  use chatter_user_id <- decode.field("chatter_user_id", decode.string)
  use chatter_user_login <- decode.field("chatter_user_login", decode.string)
  use message <- decode.field("message", message_content())
  decode.success(ChatMessage(
    broadcaster_user_id:,
    broadcaster_user_login:,
    chatter_user_id:,
    chatter_user_login:,
    message:,
  ))
}

/// Decoder for the `message` object on a chat notification.
pub fn message_content() -> decode.Decoder(MessageContent) {
  use text <- decode.field("text", decode.string)
  use fragments <- decode.optional_field(
    "fragments",
    [],
    decode.list(message_fragment()),
  )
  decode.success(MessageContent(text:, fragments:))
}

/// Decoder for a single fragment in `message.fragments`.
///
/// Falls back to `Text` for unknown fragment types so we never drop content.
pub fn message_fragment() -> decode.Decoder(MessageFragment) {
  use frag_type <- decode.field("type", decode.string)
  use text <- decode.field("text", decode.string)
  case frag_type {
    "emote" -> emote_fragment(text)
    "mention" -> mention_fragment(text)
    "cheermote" -> cheermote_fragment(text)
    _ -> decode.success(Text(text:))
  }
}

/// Like `decode.optional_field`, but also falls back to the default when the
/// field is present as `null` or otherwise fails to decode. Twitch sometimes
/// sends `null` for sibling payload objects (e.g. `"emote": null` on a
/// `mention` fragment), and we should never let that fail a whole event.
fn nullable_field(
  name: String,
  default: a,
  decoder: decode.Decoder(a),
) -> decode.Decoder(a) {
  use value <- decode.optional_field(
    name,
    default,
    decode.one_of(decoder, [decode.success(default)]),
  )
  decode.success(value)
}

fn emote_fragment(text: String) -> decode.Decoder(MessageFragment) {
  use #(id, set_id) <- decode.then(
    nullable_field("emote", #("", ""), emote_payload()),
  )
  decode.success(Emote(text:, id:, set_id:))
}

fn emote_payload() -> decode.Decoder(#(String, String)) {
  use id <- decode.optional_field("id", "", decode.string)
  use set_id <- decode.optional_field("emote_set_id", "", decode.string)
  decode.success(#(id, set_id))
}

fn mention_fragment(text: String) -> decode.Decoder(MessageFragment) {
  use #(user_id, user_login) <- decode.then(
    nullable_field("mention", #("", ""), mention_payload()),
  )
  decode.success(Mention(text:, user_id:, user_login:))
}

fn mention_payload() -> decode.Decoder(#(String, String)) {
  use user_id <- decode.optional_field("user_id", "", decode.string)
  use user_login <- decode.optional_field("user_login", "", decode.string)
  decode.success(#(user_id, user_login))
}

fn cheermote_fragment(text: String) -> decode.Decoder(MessageFragment) {
  use #(prefix, bits, tier) <- decode.then(
    nullable_field("cheermote", #("", 0, 0), cheermote_payload()),
  )
  decode.success(Cheermote(text:, prefix:, bits:, tier:))
}

fn cheermote_payload() -> decode.Decoder(#(String, Int, Int)) {
  use prefix <- decode.optional_field("prefix", "", decode.string)
  use bits <- decode.optional_field("bits", 0, decode.int)
  use tier <- decode.optional_field("tier", 0, decode.int)
  decode.success(#(prefix, bits, tier))
}

/// Decoder for the `data` array element in subscription create/list responses.
pub fn subscription_id() -> decode.Decoder(String) {
  use id <- decode.field("id", decode.string)
  decode.success(id)
}
