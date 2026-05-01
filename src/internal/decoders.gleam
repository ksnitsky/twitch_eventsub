import gleam/dynamic/decode
import gleam/option.{type Option, None}
import types.{
  type Badge, type ChatMessage, type Cheer, type MessageContent,
  type MessageFragment, type Reply, Badge, ChatMessage, Cheer, Cheermote, Emote,
  Mention, MessageContent, Reply, Text,
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

/// Decoder for `payload.event` of `channel.chat.message`. Surfaces all
/// documented fields; nullable ones come through as `Option`.
pub fn chat_message() -> decode.Decoder(ChatMessage) {
  use broadcaster_user_id <- decode.field("broadcaster_user_id", decode.string)
  use broadcaster_user_login <- decode.field(
    "broadcaster_user_login",
    decode.string,
  )
  use broadcaster_user_name <- decode.optional_field(
    "broadcaster_user_name",
    "",
    decode.string,
  )
  use chatter_user_id <- decode.field("chatter_user_id", decode.string)
  use chatter_user_login <- decode.field("chatter_user_login", decode.string)
  use chatter_user_name <- decode.optional_field(
    "chatter_user_name",
    "",
    decode.string,
  )
  use message_id <- decode.optional_field("message_id", "", decode.string)
  use message_type <- decode.optional_field("message_type", "", decode.string)
  use message <- decode.field("message", message_content())
  use color <- decode.optional_field("color", "", decode.string)
  use badges <- decode.optional_field("badges", [], decode.list(badge()))
  use cheer <- nullable_optional_field("cheer", cheer_decoder())
  use reply <- nullable_optional_field("reply", reply_decoder())
  use channel_points_custom_reward_id <- nullable_optional_field(
    "channel_points_custom_reward_id",
    decode.string,
  )
  use source_broadcaster_user_id <- nullable_optional_field(
    "source_broadcaster_user_id",
    decode.string,
  )
  use source_broadcaster_user_login <- nullable_optional_field(
    "source_broadcaster_user_login",
    decode.string,
  )
  use source_broadcaster_user_name <- nullable_optional_field(
    "source_broadcaster_user_name",
    decode.string,
  )
  use source_message_id <- nullable_optional_field(
    "source_message_id",
    decode.string,
  )
  use source_badges <- nullable_optional_field(
    "source_badges",
    decode.list(badge()),
  )
  decode.success(ChatMessage(
    broadcaster_user_id:,
    broadcaster_user_login:,
    broadcaster_user_name:,
    chatter_user_id:,
    chatter_user_login:,
    chatter_user_name:,
    message_id:,
    message_type:,
    message:,
    color:,
    badges:,
    cheer:,
    reply:,
    channel_points_custom_reward_id:,
    source_broadcaster_user_id:,
    source_broadcaster_user_login:,
    source_broadcaster_user_name:,
    source_message_id:,
    source_badges:,
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

fn badge() -> decode.Decoder(Badge) {
  use set_id <- decode.optional_field("set_id", "", decode.string)
  use id <- decode.optional_field("id", "", decode.string)
  use info <- decode.optional_field("info", "", decode.string)
  decode.success(Badge(set_id:, id:, info:))
}

fn cheer_decoder() -> decode.Decoder(Cheer) {
  use bits <- decode.optional_field("bits", 0, decode.int)
  decode.success(Cheer(bits:))
}

fn reply_decoder() -> decode.Decoder(Reply) {
  use parent_message_id <- decode.optional_field(
    "parent_message_id",
    "",
    decode.string,
  )
  use parent_message_body <- decode.optional_field(
    "parent_message_body",
    "",
    decode.string,
  )
  use parent_user_id <- decode.optional_field(
    "parent_user_id",
    "",
    decode.string,
  )
  use parent_user_login <- decode.optional_field(
    "parent_user_login",
    "",
    decode.string,
  )
  use parent_user_name <- decode.optional_field(
    "parent_user_name",
    "",
    decode.string,
  )
  use thread_message_id <- decode.optional_field(
    "thread_message_id",
    "",
    decode.string,
  )
  use thread_user_id <- decode.optional_field(
    "thread_user_id",
    "",
    decode.string,
  )
  use thread_user_login <- decode.optional_field(
    "thread_user_login",
    "",
    decode.string,
  )
  use thread_user_name <- decode.optional_field(
    "thread_user_name",
    "",
    decode.string,
  )
  decode.success(Reply(
    parent_message_id:,
    parent_message_body:,
    parent_user_id:,
    parent_user_login:,
    parent_user_name:,
    thread_message_id:,
    thread_user_id:,
    thread_user_login:,
    thread_user_name:,
  ))
}

/// `decode.optional_field` that also tolerates explicit `null`. Twitch emits
/// `null` for absent siblings (e.g. `"cheer": null` on a non-cheer message),
/// and we want those to come through as `None`, not as a decode error.
fn nullable_optional_field(
  name: String,
  decoder: decode.Decoder(a),
  k: fn(Option(a)) -> decode.Decoder(b),
) -> decode.Decoder(b) {
  decode.optional_field(
    name,
    None,
    decode.one_of(decode.optional(decoder), [decode.success(None)]),
    k,
  )
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
  use #(id, set_id, owner_id, format) <- decode.then(nullable_field(
    "emote",
    #("", "", "", []),
    emote_payload(),
  ))
  decode.success(Emote(text:, id:, set_id:, owner_id:, format:))
}

fn emote_payload() -> decode.Decoder(#(String, String, String, List(String))) {
  use id <- decode.optional_field("id", "", decode.string)
  use set_id <- decode.optional_field("emote_set_id", "", decode.string)
  use owner_id <- decode.optional_field("owner_id", "", decode.string)
  use format <- decode.optional_field("format", [], decode.list(decode.string))
  decode.success(#(id, set_id, owner_id, format))
}

fn mention_fragment(text: String) -> decode.Decoder(MessageFragment) {
  use #(user_id, user_login, user_name) <- decode.then(nullable_field(
    "mention",
    #("", "", ""),
    mention_payload(),
  ))
  decode.success(Mention(text:, user_id:, user_login:, user_name:))
}

fn mention_payload() -> decode.Decoder(#(String, String, String)) {
  use user_id <- decode.optional_field("user_id", "", decode.string)
  use user_login <- decode.optional_field("user_login", "", decode.string)
  use user_name <- decode.optional_field("user_name", "", decode.string)
  decode.success(#(user_id, user_login, user_name))
}

fn cheermote_fragment(text: String) -> decode.Decoder(MessageFragment) {
  use #(prefix, bits, tier) <- decode.then(nullable_field(
    "cheermote",
    #("", 0, 0),
    cheermote_payload(),
  ))
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
