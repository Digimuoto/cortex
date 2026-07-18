------------------------------ MODULE HostedProtocol ------------------------------
(*******************************************************************************)
(* Bounded model of the Wire process-host protocol around the circuit engine.   *)
(* The engine snapshot semantics live in Lean; this model covers host-owned      *)
(* concurrency: atomic worker registration, serialized completions, checkpoint   *)
(* acknowledgement, cancellation, independent watchdogs, terminal authority,    *)
(* and child exit.  The vocabulary mirrors Cortex.Wire.Circuit.HostProtocol.     *)
(*******************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Timeout, MaxClock

Workers == {"w1", "w2"}
Terminals == {"active", "succeeded", "cancelled"}
Outcomes == {"none", "fault", "succeeded", "cancelled"}

VARIABLES
  checkpointPending,
  checkpointAcknowledged,
  awaitingCheckpoint,
  committedTerminal,
  terminalSeen,
  workerRunning,
  workerRegistered,
  interrupted,
  buffered,
  cancelSent,
  completionAfterCancellation,
  engineObligation,
  engineStarted,
  engineDeadline,
  cancellationObligation,
  cancellationStarted,
  cancellationDeadline,
  childExited,
  outcome,
  clock,
  traffic

vars == <<
  checkpointPending,
  checkpointAcknowledged,
  awaitingCheckpoint,
  committedTerminal,
  terminalSeen,
  workerRunning,
  workerRegistered,
  interrupted,
  buffered,
  cancelSent,
  completionAfterCancellation,
  engineObligation,
  engineStarted,
  engineDeadline,
  cancellationObligation,
  cancellationStarted,
  cancellationDeadline,
  childExited,
  outcome,
  clock,
  traffic
>>

TypeOK ==
  /\ checkpointPending \in BOOLEAN
  /\ checkpointAcknowledged \in BOOLEAN
  /\ awaitingCheckpoint \in BOOLEAN
  /\ committedTerminal \in Terminals
  /\ terminalSeen \in Terminals \cup {"none"}
  /\ workerRunning \subseteq Workers
  /\ workerRegistered \subseteq Workers
  /\ interrupted \subseteq Workers
  /\ buffered \subseteq Workers
  /\ cancelSent \in BOOLEAN
  /\ completionAfterCancellation \in BOOLEAN
  /\ engineObligation \in BOOLEAN
  /\ engineStarted \in 0..MaxClock
  /\ engineDeadline \in 0..(MaxClock + Timeout)
  /\ cancellationObligation \in BOOLEAN
  /\ cancellationStarted \in 0..MaxClock
  /\ cancellationDeadline \in 0..(MaxClock + Timeout)
  /\ childExited \in BOOLEAN
  /\ outcome \in Outcomes
  /\ clock \in 0..MaxClock
  /\ traffic \in 0..1

Init ==
  /\ checkpointPending = FALSE
  /\ checkpointAcknowledged = FALSE
  /\ awaitingCheckpoint = FALSE
  /\ committedTerminal = "active"
  /\ terminalSeen = "none"
  /\ workerRunning = {}
  /\ workerRegistered = {}
  /\ interrupted = {}
  /\ buffered = {}
  /\ cancelSent = FALSE
  /\ completionAfterCancellation = FALSE
  /\ engineObligation = TRUE
  /\ engineStarted = 0
  /\ engineDeadline = Timeout
  /\ cancellationObligation = FALSE
  /\ cancellationStarted = 0
  /\ cancellationDeadline = 0
  /\ childExited = FALSE
  /\ outcome = "none"
  /\ clock = 0
  /\ traffic = 0

ReceiveInitialCheckpoint ==
  /\ outcome = "none"
  /\ terminalSeen = "none"
  /\ ~checkpointAcknowledged
  /\ ~checkpointPending
  /\ engineObligation
  /\ checkpointPending' = TRUE
  /\ awaitingCheckpoint' = TRUE
  /\ committedTerminal' = "active"
  /\ engineObligation' = FALSE
  /\ UNCHANGED <<
       checkpointAcknowledged, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, cancelSent, completionAfterCancellation,
       engineStarted, engineDeadline, cancellationObligation,
       cancellationStarted, cancellationDeadline, childExited, outcome,
       clock, traffic
     >>

StartSuccessor ==
  \E worker \in Workers:
    /\ outcome = "none"
    /\ checkpointAcknowledged
    /\ ~checkpointPending
    /\ committedTerminal = "active"
    /\ terminalSeen = "none"
    /\ ~cancelSent
    /\ interrupted = {}
    /\ worker \notin workerRunning
    /\ workerRunning' = workerRunning \cup {worker}
    /\ workerRegistered' = workerRegistered \cup {worker}
    /\ engineObligation' = FALSE
    /\ UNCHANGED <<
         checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
         committedTerminal, terminalSeen, interrupted, buffered, cancelSent,
         completionAfterCancellation, engineStarted, engineDeadline,
         cancellationObligation, cancellationStarted, cancellationDeadline,
         childExited, outcome, clock, traffic
       >>

FinishWorker ==
  \E worker \in workerRunning:
    /\ outcome = "none"
    /\ workerRunning' = workerRunning \ {worker}
    /\ workerRegistered' = workerRegistered \ {worker}
    /\ IF cancelSent \/ interrupted # {}
          THEN /\ buffered' = buffered
               /\ awaitingCheckpoint' = awaitingCheckpoint
               /\ engineObligation' = engineObligation
               /\ engineStarted' = engineStarted
               /\ engineDeadline' = engineDeadline
               /\ completionAfterCancellation' = completionAfterCancellation
          ELSE IF awaitingCheckpoint
            THEN /\ buffered' = buffered \cup {worker}
                 /\ awaitingCheckpoint' = awaitingCheckpoint
                 /\ engineObligation' = engineObligation
                 /\ engineStarted' = engineStarted
                 /\ engineDeadline' = engineDeadline
                 /\ completionAfterCancellation' = completionAfterCancellation
            ELSE /\ buffered' = buffered
                 /\ awaitingCheckpoint' = TRUE
                 /\ engineObligation' = TRUE
                 /\ engineStarted' = clock
                 /\ engineDeadline' = clock + Timeout
                 /\ completionAfterCancellation' =
                      completionAfterCancellation \/ cancelSent
    /\ UNCHANGED <<
         checkpointPending, checkpointAcknowledged, committedTerminal,
         terminalSeen, interrupted, cancelSent, cancellationObligation,
         cancellationStarted, cancellationDeadline, childExited, outcome,
         clock, traffic
       >>

InterruptWorker ==
  \E worker \in workerRunning:
    /\ outcome = "none"
    /\ ~cancelSent
    /\ workerRunning' = workerRunning \ {worker}
    /\ workerRegistered' = workerRegistered \ {worker}
    /\ interrupted' = interrupted \cup {worker}
    /\ cancellationObligation' = TRUE
    /\ IF cancellationObligation
          THEN /\ cancellationStarted' = cancellationStarted
               /\ cancellationDeadline' = cancellationDeadline
          ELSE /\ cancellationStarted' = clock
               /\ cancellationDeadline' = clock + Timeout
    /\ UNCHANGED <<
         checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
         committedTerminal, terminalSeen, buffered, cancelSent,
         completionAfterCancellation, engineObligation, engineStarted,
         engineDeadline, childExited, outcome, clock, traffic
       >>

SendCancellation ==
  /\ outcome = "none"
  /\ interrupted # {}
  /\ ~cancelSent
  /\ cancelSent' = TRUE
  /\ cancellationObligation' = FALSE
  /\ IF engineObligation
        THEN /\ engineObligation' = engineObligation
             /\ engineStarted' = engineStarted
             /\ engineDeadline' = engineDeadline
        ELSE /\ engineObligation' = TRUE
             /\ engineStarted' = clock
             /\ engineDeadline' = clock + Timeout
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, completionAfterCancellation,
       cancellationStarted, cancellationDeadline, childExited, outcome,
       clock, traffic
     >>

ReceiveActiveCheckpoint ==
  /\ outcome = "none"
  /\ terminalSeen = "none"
  /\ checkpointAcknowledged
  /\ ~checkpointPending
  /\ engineObligation
  /\ checkpointPending' = TRUE
  /\ awaitingCheckpoint' = TRUE
  /\ committedTerminal' = "active"
  /\ IF cancelSent
        THEN /\ engineObligation' = engineObligation
             /\ engineStarted' = engineStarted
             /\ engineDeadline' = engineDeadline
        ELSE /\ engineObligation' = FALSE
             /\ engineStarted' = engineStarted
             /\ engineDeadline' = engineDeadline
  /\ UNCHANGED <<
       checkpointAcknowledged, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, cancelSent, completionAfterCancellation,
       cancellationObligation, cancellationStarted, cancellationDeadline,
       childExited, outcome, clock, traffic
     >>

ReceiveTerminalCheckpoint ==
  \E terminal \in {"succeeded", "cancelled"}:
    /\ outcome = "none"
    /\ terminalSeen = "none"
    /\ checkpointAcknowledged
    /\ ~checkpointPending
    /\ engineObligation
    /\ IF terminal = "cancelled" THEN cancelSent ELSE ~cancelSent
    /\ IF terminal = "succeeded"
          THEN workerRunning = {} /\ interrupted = {} /\ buffered = {}
          ELSE TRUE
    /\ checkpointPending' = TRUE
    /\ awaitingCheckpoint' = TRUE
    /\ committedTerminal' = terminal
    /\ engineObligation' = FALSE
    /\ UNCHANGED <<
         checkpointAcknowledged, terminalSeen, workerRunning,
         workerRegistered, interrupted, buffered, cancelSent,
         completionAfterCancellation, engineStarted, engineDeadline,
         cancellationObligation, cancellationStarted, cancellationDeadline,
         childExited, outcome, clock, traffic
       >>

AcknowledgeCheckpoint ==
  /\ outcome = "none"
  /\ checkpointPending
  /\ checkpointPending' = FALSE
  /\ checkpointAcknowledged' = TRUE
  /\ IF cancelSent /\ buffered # {}
        THEN /\ buffered' = {}
             /\ awaitingCheckpoint' = FALSE
             /\ engineObligation' = TRUE
             /\ engineStarted' = engineStarted
             /\ engineDeadline' = engineDeadline
        ELSE IF buffered # {}
          THEN /\ buffered' = buffered \ {CHOOSE worker \in buffered: TRUE}
               /\ awaitingCheckpoint' = TRUE
               /\ engineObligation' = TRUE
               /\ engineStarted' = clock
               /\ engineDeadline' = clock + Timeout
          ELSE /\ buffered' = buffered
               /\ awaitingCheckpoint' = FALSE
               /\ engineObligation' = TRUE
               /\ engineStarted' = clock
               /\ engineDeadline' = clock + Timeout
  /\ UNCHANGED <<
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, cancelSent, completionAfterCancellation,
       cancellationObligation, cancellationStarted, cancellationDeadline,
       childExited, outcome, clock, traffic
     >>

ObserveTerminal ==
  /\ outcome = "none"
  /\ committedTerminal # "active"
  /\ checkpointAcknowledged
  /\ ~checkpointPending
  /\ ~awaitingCheckpoint
  /\ IF committedTerminal = "succeeded"
        THEN workerRunning = {} /\ interrupted = {} /\ buffered = {}
        ELSE TRUE
  /\ terminalSeen' = committedTerminal
  /\ workerRunning' = {}
  /\ workerRegistered' = {}
  /\ interrupted' = {}
  /\ buffered' = {}
  /\ engineObligation' = TRUE
  /\ engineStarted' = clock
  /\ engineDeadline' = clock + Timeout
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, cancelSent, completionAfterCancellation,
       cancellationObligation, cancellationStarted, cancellationDeadline,
       childExited, outcome, clock, traffic
     >>

AbnormalChildExit ==
  /\ outcome = "none"
  /\ terminalSeen # "none"
  /\ childExited' = TRUE
  /\ outcome' = terminalSeen
  /\ engineObligation' = FALSE
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, cancelSent, completionAfterCancellation,
       engineStarted, engineDeadline, cancellationObligation,
       cancellationStarted, cancellationDeadline, clock, traffic
     >>

EngineTimeout ==
  /\ outcome = "none"
  /\ engineObligation
  /\ clock >= engineDeadline
  /\ outcome' = IF terminalSeen # "none" THEN terminalSeen ELSE "fault"
  /\ engineObligation' = FALSE
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, cancelSent, completionAfterCancellation,
       engineStarted, engineDeadline, cancellationObligation,
       cancellationStarted, cancellationDeadline, childExited, clock, traffic
     >>

CancellationTimeout ==
  /\ outcome = "none"
  /\ cancellationObligation
  /\ clock >= cancellationDeadline
  /\ outcome' = "fault"
  /\ cancellationObligation' = FALSE
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, cancelSent, completionAfterCancellation,
       engineObligation, engineStarted, engineDeadline, cancellationStarted,
       cancellationDeadline, childExited, clock, traffic
     >>

Tick ==
  /\ outcome = "none"
  /\ clock < MaxClock
  /\ clock' = clock + 1
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, cancelSent, completionAfterCancellation,
       engineObligation, engineStarted, engineDeadline,
       cancellationObligation, cancellationStarted, cancellationDeadline,
       childExited, outcome, traffic
     >>

UnrelatedTraffic ==
  /\ outcome = "none"
  /\ traffic' = 1 - traffic
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, cancelSent, completionAfterCancellation,
       engineObligation, engineStarted, engineDeadline,
       cancellationObligation, cancellationStarted, cancellationDeadline,
       childExited, outcome, clock
     >>

Done ==
  /\ outcome # "none"
  /\ UNCHANGED vars

Next ==
  \/ ReceiveInitialCheckpoint
  \/ StartSuccessor
  \/ FinishWorker
  \/ InterruptWorker
  \/ SendCancellation
  \/ ReceiveActiveCheckpoint
  \/ ReceiveTerminalCheckpoint
  \/ AcknowledgeCheckpoint
  \/ ObserveTerminal
  \/ AbnormalChildExit
  \/ EngineTimeout
  \/ CancellationTimeout
  \/ Tick
  \/ UnrelatedTraffic
  \/ Done

Fairness ==
  /\ WF_vars(SendCancellation)
  /\ WF_vars(EngineTimeout)
  /\ WF_vars(CancellationTimeout)

Spec == Init /\ [][Next]_vars /\ Fairness

(************************ Model-checked host obligations ************************)
AcknowledgementBeforeSuccessor ==
  workerRunning # {} => checkpointAcknowledged

WorkerRegistrationAtomic == workerRunning \subseteq workerRegistered

TerminalCheckpointAuthority ==
  terminalSeen # "none" =>
    terminalSeen = committedTerminal /\ checkpointAcknowledged /\ ~checkpointPending

NoCompletionAfterCancellation == ~completionAfterCancellation

EngineDeadlineNotExtended ==
  engineObligation => engineDeadline = engineStarted + Timeout

CancellationDeadlineIndependent ==
  cancellationObligation => cancellationDeadline = cancellationStarted + Timeout

BufferedCompletionIsGated == buffered # {} => awaitingCheckpoint

CommittedTerminalSurvivesAbnormalExit ==
  childExited => outcome = committedTerminal

CancellationLivenessAfterInterruption ==
  [](interrupted # {} => <>(cancelSent \/ outcome # "none"))

=============================================================================
