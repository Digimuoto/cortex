---------------------------- MODULE RunTerminalSignal ----------------------------
(***************************************************************************)
(* Model of the Pulse run-terminal "await a run without polling" protocol.*)
(*                                                                         *)
(* A parent run suspends on a child run's terminal signal. This spec       *)
(* captures the suspend/deliver protocol at the run level and demonstrates *)
(* the lost-wakeup bug class:                                              *)
(*                                                                         *)
(*   Atomic = TRUE  models `settleSuspend`: the FOR-SHARE check, the wait  *)
(*                  row, and the park commit as ONE transaction.           *)
(*   Atomic = FALSE models the pre-refactor split: the frontier registers  *)
(*                  the wait row in one step and `handleSuspended` parks    *)
(*                  the run in a later step (the historical code, before    *)
(*                  the post-park recheck was bolted on).                   *)
(*                                                                         *)
(* The state invariant NoStuckWaiter holds under Atomic = TRUE and is      *)
(* violated under Atomic = FALSE; the violating trace IS the lost wakeup.  *)
(*                                                                         *)
(* SCOPE: this model covers only the run-terminal: signal family, whose    *)
(* delivery resolves the waiter to "done". The reserved external-call:     *)
(* family (ADR 0059) instead RE-ARMS the waiter (back to NodePending) and  *)
(* may re-suspend on a not-yet-terminal provider job. That family-specific *)
(* settlement and its liveness (the wake -> re-suspend -> wake loop        *)
(* terminating under provider eventual-terminality) are NOT modeled here   *)
(* and are a separate obligation to discharge when ADR 0059 is implemented.*)
(***************************************************************************)
EXTENDS Naturals

CONSTANT Atomic   \* TRUE: one-step settlement; FALSE: register-then-park split

VARIABLES
  child,   \* "running" | "terminal"  -- the awaited child run
  parent,  \* "running" | "registered" | "waiting" | "pending" | "done"
  sig      \* "none" | "pending" | "delivered"  -- the parent's wait row on child

vars == <<child, parent, sig>>

ParentStatus == {"running", "registered", "waiting", "pending", "done"}
SigStatus    == {"none", "pending", "delivered"}
ChildStatus  == {"running", "terminal"}

TypeOK ==
  /\ child  \in ChildStatus
  /\ parent \in ParentStatus
  /\ sig    \in SigStatus

Init ==
  /\ child  = "running"
  /\ parent = "running"
  /\ sig    = "none"

(*-------------------------- Settlement (atomic) --------------------------*)
(* One transaction: FOR-SHARE-read the child; if already terminal, resolve *)
(* the wait immediately (no park); otherwise register the pending wait AND *)
(* park, together.                                                         *)
SettleAtomic ==
  /\ Atomic
  /\ parent = "running"
  /\ sig = "none"
  /\ IF child = "terminal"
       THEN /\ sig' = "delivered"     \* resolve at registration
            /\ parent' = "running"    \* not parked; proceeds to finish
       ELSE /\ sig' = "pending"
            /\ parent' = "waiting"    \* register + park in one step
  /\ UNCHANGED child

(*--------------------- Settlement (split / historical) -------------------*)
(* Step A: the frontier registers the wait row inline; the run stays       *)
(* running. Step B: handleSuspended parks the run unconditionally later    *)
(* (modelling the code BEFORE the post-park recheck existed).              *)
SettleRegister ==
  /\ ~Atomic
  /\ parent = "running"
  /\ sig = "none"
  /\ IF child = "terminal" THEN sig' = "delivered" ELSE sig' = "pending"
  /\ parent' = "registered"
  /\ UNCHANGED child

SettlePark ==
  /\ ~Atomic
  /\ parent = "registered"
  /\ parent' = "waiting"            \* unconditional park: the historical bug
  /\ UNCHANGED <<child, sig>>

(*------------------------------- Delivery --------------------------------*)
(* The child terminates; the centralized terminal writer marks the pending *)
(* wait delivered and wakes a waiting parent, atomically. The wake only    *)
(* fires if the parent is observably 'waiting' -- this is exactly why the  *)
(* split protocol loses it.                                                *)
Deliver ==
  /\ child = "running"
  /\ child' = "terminal"
  /\ sig' = IF sig = "pending" THEN "delivered" ELSE sig
  /\ parent' = IF (sig = "pending" /\ parent = "waiting") THEN "pending" ELSE parent

(*----------------------- Scheduler / completion --------------------------*)
Claim ==                       \* woken run is claimed back to running
  /\ parent = "pending"
  /\ parent' = "running"
  /\ UNCHANGED <<child, sig>>

Finish ==                      \* await satisfied; the run completes
  /\ parent = "running"
  /\ sig = "delivered"
  /\ parent' = "done"
  /\ UNCHANGED <<child, sig>>

DoneLoop ==                    \* sink: a completed run stutters (no deadlock at goal)
  /\ parent = "done"
  /\ UNCHANGED vars

Next ==
  \/ SettleAtomic
  \/ SettleRegister
  \/ SettlePark
  \/ Deliver
  \/ Claim
  \/ Finish
  \/ DoneLoop

Fairness ==
  /\ WF_vars(Deliver)
  /\ WF_vars(Claim)
  /\ WF_vars(Finish)
  /\ WF_vars(SettleAtomic \/ SettleRegister \/ SettlePark)

Spec == Init /\ [][Next]_vars /\ Fairness

(*------------------------------ Properties -------------------------------*)
(* Safety: a parked waiter is never left on an already-delivered signal.   *)
(* Under Atomic this is unreachable; under the split protocol TLC finds a  *)
(* state where parent = "waiting" /\ sig = "delivered" -- the lost wakeup. *)
NoStuckWaiter == ~(parent = "waiting" /\ sig = "delivered")

(* Liveness: every awaiting run eventually completes. *)
EventuallyDone == <>(parent = "done")

=============================================================================
