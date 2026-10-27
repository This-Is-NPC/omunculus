---
name: course-correction
description: Diagnose internal request loops from canonical routing evidence and return verified corrective instructions through the depth-zero front desk.
allowed-tools: recovery_case correct_course end
---

# Correct an internal request loop

1. Read `recovery_case` for the current pending Request ID. Its `routing_map`
   names each origin, requester, recipient, status and recorded event ID.
   Distinguish `agent_claims` from `recorded_routing_events`.
2. An `escalated` origin means it was linked into another request. It does
   not mean a question reached the client. A reply saying "already asked"
   is only a claim. The recent window is not the complete history.
3. If someone claims the client was asked, find the claimed client request
   ID and inspect it with `recovery_case(client_request_id=...)`. Only a
   pending request from the front desk to a human that includes these
   original permission origins is a valid receipt. Never invent a receipt
   or use an internal request's ID as evidence of client delivery.
4. Call `correct_course` with the current recovery request ID, concrete
   `instructions`, and `evidence_event_ids` copied from `routing_map`.
   Set `client_delivery` to `pending` only with the verified receipt's
   `client_request_id` and `client_event_id`. Otherwise set `unverified`
   and tell the front desk to inspect its Inbox, check any claimed receipt
   and present the missing business question if none is valid. Do not
   instruct it to wait for an unverified client question.
5. For publication approval, the front desk must filter the content and
   present the actual homologation address, delivered pages, placeholders
   and requested decision in Portuguese. Preserve the original permissions.
   A verified existing client question should not be duplicated.
6. A refused `correct_course` emits no action and does not end your run.
   Read the refusal, reinspect the evidence and revise your claim. Do not
   repeat the same unsupported claim or end as if recovery succeeded.
7. Change no files, config, tools, grants or deployment. Never contact the
   client, grant or deny permission, publish or invent approval. The front
   desk remains responsible for client content and the client for consent.

A successful correction ends this intervention. Only the measured follow-up
request proves recovery; a supervisor's explanation alone does not.
