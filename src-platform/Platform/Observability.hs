-- Phase A note: this module keeps the existing Portman env var names and state
-- directory defaults verbatim for compatibility. Neutralizing those runtime
-- names or splitting Platform into a separate package is deferred work.
module Platform.Observability
  ( ObservabilityRuntime,
    ObservabilityConfig (..),
    ObservabilityEnvConfig (..),
    defaultPortmanEnvConfig,
    ObservabilityLogLevel (..),
    PreviewVisibility (..),
    ObservabilityContext (..),
    ObservabilityQuery (..),
    TraceQuery (..),
    LogEventSpec (..),
    SpanSpec (..),
    SpanOutcomeSpec (..),
    loadObservabilityConfig,
    initObservabilityRuntime,
    installGlobalObservabilityRuntime,
    resetGlobalObservabilityRuntime,
    currentRuntime,
    debugEnabled,
    stateLogFile,
    stateTraceFile,
    newRequestContext,
    newLinkedRootContext,
    withThreadContext,
    withThreadContextPatch,
    captureCurrentContext,
    currentTraceHeaders,
    forkWithContext,
    forkWithSharedContext,
    defaultLogEvent,
    emitEvent,
    emitGlobalEvent,
    SubsystemEmitter (..),
    emitSubsystemEvent,
    -- Typed event codes and field builders
    ObsEventCode,
    ObsFields,
    field,
    fields,
    noFields,
    toFieldList,
    -- Typed event typeclass
    ToObsEvent (..),
    emitObsEvent,
    defaultSpanSpec,
    withSpanIO,
    withSpanOutcomeIO,
    mkRequestMiddleware,
    queryLogs,
    queryTraces,
    redactText,
    redactValue,
    valueTextField,
    valueIntField,
  )
where

import Platform.Observability.Context
  ( captureCurrentContext,
    currentTraceHeaders,
    forkWithContext,
    forkWithSharedContext,
    newLinkedRootContext,
    withThreadContext,
    withThreadContextPatch,
  )
import Platform.Observability.Emit
  ( SubsystemEmitter (..),
    emitEvent,
    emitGlobalEvent,
    emitObsEvent,
    emitSubsystemEvent,
    withSpanIO,
    withSpanOutcomeIO,
  )
import Platform.Observability.Fields
  ( ObsEventCode,
    ObsFields,
    ToObsEvent (..),
    field,
    fields,
    noFields,
    toFieldList,
  )
import Platform.Observability.Redaction
  ( redactText,
    redactValue,
  )
import Platform.Observability.Runtime
  ( currentRuntime,
    debugEnabled,
    initObservabilityRuntime,
    installGlobalObservabilityRuntime,
    loadObservabilityConfig,
    resetGlobalObservabilityRuntime,
    stateLogFile,
    stateTraceFile,
  )
import Platform.Observability.Store
  ( queryLogs,
    queryTraces,
    valueIntField,
    valueTextField,
  )
import Platform.Observability.Types
  ( LogEventSpec (..),
    ObservabilityConfig (..),
    ObservabilityContext (..),
    ObservabilityEnvConfig (..),
    ObservabilityLogLevel (..),
    ObservabilityQuery (..),
    ObservabilityRuntime,
    PreviewVisibility (..),
    SpanOutcomeSpec (..),
    SpanSpec (..),
    TraceQuery (..),
    defaultLogEvent,
    defaultPortmanEnvConfig,
    defaultSpanSpec,
  )
import Platform.Observability.Wai
  ( mkRequestMiddleware,
    newRequestContext,
  )
