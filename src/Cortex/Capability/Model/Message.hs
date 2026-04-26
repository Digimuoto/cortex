{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Capability.Model.Message
  ( assistantToolCallsMessage,
    chatMessage,
    systemMessage,
    toolMessage,
    userTextMessage,
  )
where

import Cortex.Capability.Model.Types
  ( CortexToolCall (..),
  )
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)

assistantToolCallsMessage :: Text -> [CortexToolCall] -> Aeson.Value
assistantToolCallsMessage content toolCalls =
  Aeson.object
    [ "role" .= ("assistant" :: Text),
      "content" .= content,
      "tool_calls"
        .= fmap
          ( \call ->
              Aeson.object
                [ "id" .= call.cortexToolCallId,
                  "type" .= ("function" :: Text),
                  "function"
                    .= Aeson.object
                      [ "name" .= call.cortexToolCallName,
                        "arguments" .= call.cortexToolCallArguments
                      ]
                ]
          )
          toolCalls
    ]

chatMessage :: Text -> Text -> Aeson.Value
chatMessage role content =
  Aeson.object
    [ "role" .= role,
      "content" .= content
    ]

toolMessage :: Text -> Text -> Text -> Aeson.Value
toolMessage toolCallId toolName content =
  Aeson.object
    [ "role" .= ("tool" :: Text),
      "tool_call_id" .= toolCallId,
      "name" .= toolName,
      "content" .= content
    ]

systemMessage :: Text -> Aeson.Value
systemMessage = chatMessage "system"

userTextMessage :: Text -> Aeson.Value
userTextMessage = chatMessage "user"
