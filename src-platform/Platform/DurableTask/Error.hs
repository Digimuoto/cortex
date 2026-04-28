{- | Error handling combinators for durable task DB operations.
Provides standardized patterns for fire-and-forget and try-and-log
database writes, parameterized by a logging callback.
-}
module Platform.DurableTask.Error
  ( logDbFailure_
  , logDbFailure
  )
where

{- | Fire-and-forget: run a DB action, call @onError@ on failure, discard result.
Suitable for best-effort writes (heartbeats, schedule advances, run events).

@
logDbFailure_
 (\\err -> emitEvent ObsWarn "op.name" ("Failed: " <> T.pack err) [])
 (DB.runTransaction pool $ Q.updateSchedule ...)
@
-}
logDbFailure_ :: (String -> IO ()) -> IO (Either String a) -> IO ()
logDbFailure_ onError action = do
  result <- action
  case result of
    Left err -> onError err
    Right _ -> pure ()

{- | Try-and-log: run a DB action, call @onError@ on failure, return 'Maybe'.
Suitable for non-critical reads/writes where the caller branches on success.

@
mVal <- logDbFailure
 (\\err -> emitEvent ObsWarn "op.name" ("Failed: " <> T.pack err) [])
 (DB.withConnection pool $ Q.loadConfig ...)
case mVal of
 Nothing -> ... -- logged, but continue
 Just val -> ...
@
-}
logDbFailure :: (String -> IO ()) -> IO (Either String a) -> IO (Maybe a)
logDbFailure onError action = do
  result <- action
  case result of
    Left err -> onError err >> pure Nothing
    Right val -> pure (Just val)
