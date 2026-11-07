# LimLink device binding v1

Implementation contract, 2026-10-22. Consent: initiator selects Bind; only responder sees Accept/Reject. No SAS/code comparison. This is first-use trust of the selected TLS key, not verified ownership or protection against malicious first-use discovery substitution.

## Common rules

- Reuse mutually authenticated TLS1.3, existing port, framing and app gate `limlink`. Capability `binding-v1` in hello and optionally DNS-SD caps is not authorization. No cross-app pairing.
- Control JSON <=16,384 bytes. `requestId`, `pairId`, `bindingId` are canonical lowercase UUIDs. `token` is 32 system-random bytes, base64url unpadded (43 characters), never logged.
- Caller identity is actual TLS full SHA-256(SPKI DER) fingerprint, canonical base64url 43 characters; not JSON or names. Reject self. Caller pins selected server key.
- Fixed 120-second monotonic deadline from start, never extended by polls. One pending/accepted attempt per local device; preserve file limits. Max 3 new incoming attempts per rolling 60 seconds globally; idempotent authenticated retries of same requestId don't consume another slot. Rate error 429 `E_PAIR_RATE_LIMITED`.
- Dedicated pairing TLS connection; disconnect cancels pending/accepted attempt. Completed durable record may remain, but a unilateral record cannot auto-receive. Check run/generation and attempt before any late persistence. File-cancel must not cancel unrelated pairing; app stop clears ephemeral attempts. No implicit new-start retry.

## Control routes

Under `/limlink/v1/pair`, with existing app/header checks; available before file-session authorization. Use existing JSON error envelopes and the codes below.

### POST /start

Request: `{ "version": 1, "requestId": "uuid", "alias": "caller display name", "deviceType": "iphone|ipad|mac|windows|android" }`.

Require integer version 1, canonical requestId, current device-name validation (nonempty normalized text <=63 UTF-8 bytes, no controls/newlines), valid type. Unknown optional fields may be ignored. Version error: 400 `E_PAIR_VERSION`; malformed: 400 `E_BAD_REQUEST`.

In-memory attempt captures TLS connection/actual caller FP, requestId, own identity, alias/type, random pairId/token and deadline. Notify local UI, never auto-confirm based on file trust. Same live owner+requestId is idempotent. Competing active attempt: 409 `E_PAIR_BUSY`.

Response 202: `{ "version": 1, "pairId": "uuid", "token": "base64url32", "state": "pending", "expiresInSeconds": 120, "alias": "responder name", "deviceType": "..." }`.

Only responder UI accepts (pending->accepted) or rejects (pending->rejected). Acceptance alone does not persist active permission. Caller waits/can cancel; no caller confirmation button.

### GET /{pairId}

Require `X-LimLink-Pair-Token`, same actual owner/connection and safe token comparison. Response 200 `{ "version": 1, "pairId": "uuid", "state": "pending|accepted|completed|rejected|cancelled|expired|failed", "expiresInSeconds": N }`.

Poll no faster than 1 second, client fixed <=120-second deadline. Wrong token/owner: 403 `E_PAIR_TOKEN_INVALID`; absent/expired: 410 `E_PAIR_EXPIRED`. Rejected/cancelled/failed never authorize.

### POST /{pairId}/complete

Same token/owner/deadline, body `{}`. Only accepted may complete; pending: 409 `E_PAIR_NOT_ACCEPTED`; terminal failures fail closed. Atomically persist responder `(ownFP, callerFP, bindingId=pairId, alias, deviceType, boundAt)`, then return 200 completed state. Storage failure: 500 `E_PAIR_STORAGE_FAILED`, not success.

Duplicate complete is idempotent only while retained terminal attempt AND same active record still exist; revocation/cancel must prevent resurrection. Caller validates id/state then atomically persists own `(ownFP, responderFP, same bindingId)`, only if still current and not cancelled. Local persistence failure reports failure and best-effort cancels/revokes exact remote relationship; it cannot supply bindingId on file hello.

Lost final response may leave only responder active. Do not promise atomic rollback/bidirectional success. Explicit retry with a new attempt needs responder confirmation again.

### POST /{pairId}/cancel

Same token/owner, body `{}`. Cancel attempt, clear pending UI, remove only active relationship matching exact pairId AND caller if completion raced cancellation. Never remove a newer binding. Return 200 `{ "state": "cancelled" }`; expired auth can fail, local permission is still cleared.

### POST /{bindingId}/revoke

Body `{}`. Existing app/TLS check plus actual peer identity. No ephemeral token; authorize only matching stored peer+bindingId. Remove exact relationship and invalidate matching pending completion. Return 200 `{ "state": "revoked" }`, absent match is idempotent with no disclosure. Local unbind clears local permission first even if peer offline.

Local Unbind is a device-level gesture: remove the current grant for that peer and invalidate any unfinished same-peer replacement, even if the displayed row still contains an older bindingId. This differs from a remote revoke/cancel or failed-attempt rollback, which must remain exact-ID and must not invalidate unrelated or newer attempts. An unmatched remote revoke must not change an outgoing generation.

## File hello extension and automatic receive

Keep existing hello required fields. Optional request AND response `"bindingId": "uuid"` only if local store has active permission for actual TLS peer and current own identity. Advertise `binding-v1` through caps.

Receiver remembers request bindingId as untrusted connection metadata. For EVERY offer require current local active record for actual caller FP, current own FP and equal nonnil bindingId from THIS connection. Then call existing accept path including consent registration/owner tracking. Otherwise show existing per-file consent. Re-check store each offer so unbind affects subsequent files on an existing connection. `hello.trusted`, name, TXT, token or historical pairId alone never authorize.

Sender pins server as before; server must report same active relationship to be described as automatic reception, otherwise show normal waiting for recipient. Old clients ignore optional fields; missing/unsupported binding never creates a record and normal transfer remains supported.

## Storage and preservation

Private atomic persistence, serialized writes, scoped to own identity. Corruption, invalid IDs/FPs, unavailable storage or own-key mismatch fail closed. Android restore to another key cannot authorize. Errors observable; don't swallow writes or show success early. Names are display only.

Unbind does not retract published files or implicitly revoke a previously accepted active transfer; preserve explicit transfer cancel. File size, hash, path, concurrency, quarantine and publication safeguards unchanged.
