------------------------------ MODULE HostedProtocol ------------------------------
(*******************************************************************************)
(* Bounded model of the Wire process-host protocol. Lean proves engine snapshot  *)
(* semantics and checkpoint acceptance; this model covers host-owned workers,     *)
(* serialized completions, cancellation, independent deadlines, terminal          *)
(* precedence, and child exit. Three constants deliberately weaken race handling   *)
(* in negative configurations so the principal invariants are non-vacuous.         *)
(*******************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS Timeout, MaxClock,
          DropBufferedAfterCancellation,
          DropCompletionAfterTerminal,
          PreserveCrossingDeadline,
          StableDeadlineUnderTraffic

Workers == {"w1", "w2"}
Terminals == {"active", "succeeded", "failed", "cancelled"}
Outcomes == {"none", "fault", "succeeded", "failed", "cancelled"}

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
  operatorCancelPending,
  cancelSent,
  completionAfterCancellation,
  completionAfterTerminal,
  crossingDeadlineLost,
  deadlineExtendedByTraffic,
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
  operatorCancelPending,
  cancelSent,
  completionAfterCancellation,
  completionAfterTerminal,
  crossingDeadlineLost,
  deadlineExtendedByTraffic,
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
  /\ operatorCancelPending \in BOOLEAN
  /\ cancelSent \in BOOLEAN
  /\ completionAfterCancellation \in BOOLEAN
  /\ completionAfterTerminal \in BOOLEAN
  /\ crossingDeadlineLost \in BOOLEAN
  /\ deadlineExtendedByTraffic \in BOOLEAN
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
  /\ operatorCancelPending \in BOOLEAN
  /\ cancelSent = FALSE
  /\ completionAfterCancellation = FALSE
  /\ completionAfterTerminal = FALSE
  /\ crossingDeadlineLost = FALSE
  /\ deadlineExtendedByTraffic = FALSE
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
  \E terminal \in Terminals:
  /\ outcome = "none"
  /\ terminalSeen = "none"
  /\ ~checkpointAcknowledged
  /\ ~checkpointPending
  /\ engineObligation
  /\ checkpointPending' = TRUE
  /\ awaitingCheckpoint' = TRUE
  /\ committedTerminal' = terminal
  /\ engineObligation' = FALSE
  /\ UNCHANGED <<
       checkpointAcknowledged, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, operatorCancelPending, cancelSent,
       completionAfterCancellation, completionAfterTerminal,
       crossingDeadlineLost, deadlineExtendedByTraffic,
       engineStarted, engineDeadline,
       cancellationObligation, cancellationStarted, cancellationDeadline,
       childExited, outcome, clock, traffic
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
    /\ IF awaitingCheckpoint /\ engineObligation
          THEN IF PreserveCrossingDeadline
            THEN /\ engineObligation' = engineObligation
                 /\ crossingDeadlineLost' = crossingDeadlineLost
            ELSE /\ engineObligation' = FALSE
                 /\ crossingDeadlineLost' = TRUE
          ELSE /\ engineObligation' = FALSE
               /\ crossingDeadlineLost' = crossingDeadlineLost
    /\ UNCHANGED <<
         checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
         committedTerminal, terminalSeen, interrupted, buffered,
         operatorCancelPending, cancelSent, completionAfterCancellation,
         completionAfterTerminal, deadlineExtendedByTraffic,
         engineStarted, engineDeadline,
         cancellationObligation, cancellationStarted, cancellationDeadline,
         childExited, outcome, clock, traffic
       >>

FinishWorker ==
  \E worker \in workerRunning:
    /\ outcome = "none"
    /\ workerRunning' = workerRunning \ {worker}
    /\ workerRegistered' = workerRegistered \ {worker}
    /\ IF committedTerminal # "active" \/ terminalSeen # "none" \/ cancelSent \/ interrupted # {}
          THEN /\ buffered' = buffered
               /\ awaitingCheckpoint' = awaitingCheckpoint
               /\ engineObligation' = engineObligation
               /\ engineStarted' = engineStarted
               /\ engineDeadline' = engineDeadline
               /\ completionAfterCancellation' = completionAfterCancellation
               /\ completionAfterTerminal' =
                    IF committedTerminal # "active" \/ terminalSeen # "none"
                      THEN IF DropCompletionAfterTerminal
                        THEN completionAfterTerminal
                        ELSE TRUE
                      ELSE completionAfterTerminal
          ELSE IF awaitingCheckpoint
            THEN /\ buffered' = buffered \cup {worker}
                 /\ awaitingCheckpoint' = awaitingCheckpoint
                 /\ engineObligation' = engineObligation
                 /\ engineStarted' = engineStarted
                 /\ engineDeadline' = engineDeadline
                 /\ completionAfterCancellation' = completionAfterCancellation
                 /\ completionAfterTerminal' = completionAfterTerminal
            ELSE /\ buffered' = buffered
                 /\ awaitingCheckpoint' = TRUE
                 /\ engineObligation' = TRUE
                 /\ engineStarted' = clock
                 /\ engineDeadline' = clock + Timeout
                 /\ completionAfterCancellation' = completionAfterCancellation \/ cancelSent
                 /\ completionAfterTerminal' = completionAfterTerminal \/ committedTerminal # "active" \/ terminalSeen # "none"
    /\ UNCHANGED <<
         checkpointPending, checkpointAcknowledged, committedTerminal,
         terminalSeen, interrupted, operatorCancelPending, cancelSent,
         crossingDeadlineLost, deadlineExtendedByTraffic,
         cancellationObligation, cancellationStarted, cancellationDeadline,
         childExited, outcome, clock, traffic
       >>

InterruptWorker ==
  \E worker \in workerRunning:
    /\ outcome = "none"
    /\ committedTerminal = "active"
    /\ terminalSeen = "none"
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
         committedTerminal, terminalSeen, buffered, operatorCancelPending,
         cancelSent, completionAfterCancellation, completionAfterTerminal,
         crossingDeadlineLost, deadlineExtendedByTraffic,
         engineObligation, engineStarted, engineDeadline,
         childExited, outcome, clock, traffic
       >>

SendCancellation ==
  /\ outcome = "none"
  /\ committedTerminal = "active"
  /\ terminalSeen = "none"
  /\ operatorCancelPending \/ interrupted # {}
  /\ ~cancelSent
  /\ operatorCancelPending' = FALSE
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
       completionAfterTerminal, crossingDeadlineLost,
       deadlineExtendedByTraffic, cancellationStarted,
       cancellationDeadline, childExited, outcome, clock, traffic
     >>

ReceiveActiveCheckpoint ==
  /\ outcome = "none"
  /\ terminalSeen = "none"
  /\ committedTerminal = "active"
  /\ checkpointAcknowledged
  /\ ~checkpointPending
  /\ engineObligation
  /\ checkpointPending' = TRUE
  /\ awaitingCheckpoint' = TRUE
  /\ IF cancelSent
        THEN /\ engineObligation' = engineObligation
             /\ engineStarted' = engineStarted
             /\ engineDeadline' = engineDeadline
        ELSE /\ engineObligation' = FALSE
             /\ engineStarted' = engineStarted
             /\ engineDeadline' = engineDeadline
  /\ UNCHANGED <<
       checkpointAcknowledged, committedTerminal, terminalSeen,
       workerRunning, workerRegistered, interrupted, buffered,
       operatorCancelPending, cancelSent, completionAfterCancellation,
       completionAfterTerminal, crossingDeadlineLost,
       deadlineExtendedByTraffic, cancellationObligation,
       cancellationStarted, cancellationDeadline, childExited,
       outcome, clock, traffic
     >>

ReceiveTerminalCheckpoint ==
  \E terminal \in {"succeeded", "failed", "cancelled"}:
    /\ outcome = "none"
    /\ terminalSeen = "none"
    /\ committedTerminal = "active"
    /\ checkpointAcknowledged
    /\ ~checkpointPending
    /\ engineObligation
    /\ IF terminal = "succeeded"
          THEN workerRunning = {} /\ interrupted = {} /\ buffered = {}
          ELSE TRUE
    /\ checkpointPending' = TRUE
    /\ awaitingCheckpoint' = TRUE
    /\ committedTerminal' = terminal
    /\ engineObligation' = FALSE
    /\ cancellationObligation' = FALSE
    /\ UNCHANGED <<
         checkpointAcknowledged, terminalSeen, workerRunning,
         workerRegistered, interrupted, buffered, operatorCancelPending,
         cancelSent, completionAfterCancellation, completionAfterTerminal,
         crossingDeadlineLost, deadlineExtendedByTraffic,
         engineStarted, engineDeadline,
         cancellationStarted, cancellationDeadline, childExited,
         outcome, clock, traffic
       >>

AcknowledgeCheckpoint ==
  /\ outcome = "none"
  /\ checkpointPending
  /\ checkpointPending' = FALSE
  /\ checkpointAcknowledged' = TRUE
  /\ IF committedTerminal # "active"
        THEN /\ buffered' = {}
             /\ awaitingCheckpoint' = FALSE
             /\ engineObligation' = TRUE
             /\ engineStarted' = clock
             /\ engineDeadline' = clock + Timeout
             /\ completionAfterCancellation' =
                  IF DropBufferedAfterCancellation
                    THEN completionAfterCancellation
                    ELSE completionAfterCancellation \/ (cancelSent /\ buffered # {})
             /\ completionAfterTerminal' = completionAfterTerminal
        ELSE IF cancelSent /\ buffered # {}
          THEN /\ buffered' = {}
               /\ awaitingCheckpoint' = FALSE
               /\ engineObligation' = TRUE
               /\ engineStarted' = engineStarted
               /\ engineDeadline' = engineDeadline
               /\ completionAfterCancellation' =
                    IF DropBufferedAfterCancellation
                      THEN completionAfterCancellation
                      ELSE TRUE
               /\ completionAfterTerminal' = completionAfterTerminal
          ELSE IF buffered # {}
            THEN /\ buffered' = buffered \ {CHOOSE worker \in buffered: TRUE}
                 /\ awaitingCheckpoint' = TRUE
                 /\ engineObligation' = TRUE
                 /\ engineStarted' = clock
                 /\ engineDeadline' = clock + Timeout
                 /\ completionAfterCancellation' = completionAfterCancellation \/ cancelSent
                 /\ completionAfterTerminal' = completionAfterTerminal \/ committedTerminal # "active"
            ELSE IF cancelSent
              THEN /\ buffered' = buffered
                   /\ awaitingCheckpoint' = FALSE
                   /\ engineObligation' = TRUE
                   /\ engineStarted' = engineStarted
                   /\ engineDeadline' = engineDeadline
                   /\ completionAfterCancellation' = completionAfterCancellation
                   /\ completionAfterTerminal' = completionAfterTerminal
              ELSE IF workerRunning # {} \/ interrupted # {}
                THEN /\ buffered' = buffered
                     /\ awaitingCheckpoint' = FALSE
                     /\ engineObligation' = FALSE
                     /\ engineStarted' = engineStarted
                     /\ engineDeadline' = engineDeadline
                     /\ completionAfterCancellation' = completionAfterCancellation
                     /\ completionAfterTerminal' = completionAfterTerminal
                ELSE /\ buffered' = buffered
                     /\ awaitingCheckpoint' = FALSE
                     /\ engineObligation' = TRUE
                     /\ engineStarted' = clock
                     /\ engineDeadline' = clock + Timeout
                     /\ completionAfterCancellation' = completionAfterCancellation
                     /\ completionAfterTerminal' = completionAfterTerminal
  /\ UNCHANGED <<
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, operatorCancelPending, cancelSent,
       crossingDeadlineLost, deadlineExtendedByTraffic,
       cancellationObligation, cancellationStarted, cancellationDeadline,
       childExited, outcome, clock, traffic
     >>

ObserveTerminal ==
  /\ outcome = "none"
  /\ terminalSeen = "none"
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
  /\ cancellationObligation' = FALSE
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, operatorCancelPending, cancelSent,
       completionAfterCancellation, completionAfterTerminal,
       crossingDeadlineLost, deadlineExtendedByTraffic,
       cancellationStarted, cancellationDeadline, childExited,
       outcome, clock, traffic
     >>

AbnormalChildExit ==
  /\ outcome = "none"
  /\ childExited' = TRUE
  /\ outcome' = IF terminalSeen # "none" THEN terminalSeen ELSE "fault"
  /\ engineObligation' = FALSE
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, operatorCancelPending, cancelSent,
       completionAfterCancellation, completionAfterTerminal,
       crossingDeadlineLost, deadlineExtendedByTraffic,
       engineStarted, engineDeadline,
       cancellationObligation, cancellationStarted,
       cancellationDeadline, clock, traffic
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
       interrupted, buffered, operatorCancelPending, cancelSent,
       completionAfterCancellation, completionAfterTerminal,
       crossingDeadlineLost, deadlineExtendedByTraffic,
       engineStarted, engineDeadline,
       cancellationObligation, cancellationStarted,
       cancellationDeadline, childExited, clock, traffic
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
       interrupted, buffered, operatorCancelPending, cancelSent,
       completionAfterCancellation, completionAfterTerminal,
       crossingDeadlineLost, deadlineExtendedByTraffic,
       engineObligation, engineStarted, engineDeadline,
       cancellationStarted,
       cancellationDeadline, childExited, clock, traffic
     >>

Tick ==
  /\ outcome = "none"
  /\ clock < MaxClock
  /\ clock' = clock + 1
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, operatorCancelPending, cancelSent,
       completionAfterCancellation, completionAfterTerminal,
       crossingDeadlineLost, deadlineExtendedByTraffic,
       engineObligation, engineStarted, engineDeadline,
       cancellationObligation,
       cancellationStarted, cancellationDeadline, childExited,
       outcome, traffic
     >>

UnrelatedTraffic ==
  /\ outcome = "none"
  /\ traffic' = 1 - traffic
  /\ IF ~StableDeadlineUnderTraffic /\ engineObligation
        THEN /\ engineStarted' = clock
             /\ engineDeadline' = clock + Timeout
             /\ deadlineExtendedByTraffic' = TRUE
        ELSE /\ engineStarted' = engineStarted
             /\ engineDeadline' = engineDeadline
             /\ deadlineExtendedByTraffic' = deadlineExtendedByTraffic
  /\ UNCHANGED <<
       checkpointPending, checkpointAcknowledged, awaitingCheckpoint,
       committedTerminal, terminalSeen, workerRunning, workerRegistered,
       interrupted, buffered, operatorCancelPending, cancelSent,
       completionAfterCancellation, completionAfterTerminal,
       crossingDeadlineLost, engineObligation,
       cancellationObligation, cancellationStarted,
       cancellationDeadline, childExited, outcome, clock
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
  /\ WF_vars(AcknowledgeCheckpoint)
  /\ WF_vars(ObserveTerminal)
  /\ WF_vars(EngineTimeout)
  /\ WF_vars(CancellationTimeout)

Spec == Init /\ [][Next]_vars /\ Fairness

(************************ Model-checked host obligations ************************)
AcknowledgementBeforeSuccessor == workerRunning # {} => checkpointAcknowledged

WorkerRegistrationAtomic == workerRunning \subseteq workerRegistered

TerminalCheckpointAuthority ==
  terminalSeen # "none" =>
    terminalSeen = committedTerminal /\ checkpointAcknowledged /\ ~checkpointPending

TerminalCheckpointQuiescence ==
  committedTerminal = "succeeded" =>
    workerRunning = {} /\ interrupted = {} /\ buffered = {}

NoCompletionAfterCancellation == ~completionAfterCancellation

NoCompletionAfterTerminal == ~completionAfterTerminal

CrossingCheckpointDeadlinePreserved == ~crossingDeadlineLost

EngineDeadlineNotExtended ==
  engineObligation => engineDeadline = engineStarted + Timeout

DeadlineStableUnderUnrelatedTraffic == ~deadlineExtendedByTraffic

CancellationDeadlineIndependent ==
  cancellationObligation => cancellationDeadline = cancellationStarted + Timeout

BufferedCompletionIsGated == buffered # {} => awaitingCheckpoint

CommittedTerminalSurvivesAbnormalExit ==
  childExited /\ terminalSeen # "none" => outcome = committedTerminal

CancellationLiveness ==
  []( (operatorCancelPending \/ interrupted # {})
      => <>(cancelSent \/ committedTerminal # "active" \/ outcome # "none") )

=============================================================================
