/* limlink_core_testvectors.h — test build only (spec 15.10.9).
 *
 * Do not ship this header in a release app. The default build of this
 * library exports llct_* and not llc_*. The packaged test build (Cargo
 * feature bundled-llc) exports both prefixes from one library so a test
 * process can call llc_* and llct_*. Constructors with an rng script are
 * the llct_* ones. core_info's version string ends with "+testrng".
 * Numeric constants and llc_invite_status come from limlink_core.h.
 * Opaque objects use the same names. "Link only one" means C static
 * linking: do not put both .a files in one binary. With dynamic loading
 * (P/Invoke, JNI) both DLLs may be mapped at once, but an object returned
 * by one library must never be passed to the other library's functions.
 */
#ifndef LIMLINK_CORE_TESTVECTORS_H
#define LIMLINK_CORE_TESTVECTORS_H

#include "limlink_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Script longer than this is rejected with LLC_ERR_BUFFER_LEN. */
#define LLCT_RNG_SCRIPT_MAX 65536u

uint32_t   llct_abi_version(void);
llc_status llct_core_info(char *out_version, size_t out_version_len,
                          char *out_suites, size_t out_suites_len);

llc_status llct_sender_new(uint64_t now_ms,
                           const uint8_t *rng_script, size_t rng_script_len,
                           llc_sender **out);
void       llct_sender_free(llc_sender *s);
llc_status llct_sender_code(llc_sender *s, char *out, size_t out_len);
llc_status llct_sender_status(llc_sender *s, uint64_t now_ms, llc_invite_status *out);
llc_status llct_sender_accept_hello(llc_sender *s,
        const uint8_t *nonce_r, size_t nonce_r_len,
        const char *peer_suites, size_t peer_suites_len,
        uint64_t now_ms,
        char *out_session_id, size_t out_session_id_len,
        uint8_t *out_nonce_s, size_t out_nonce_s_len,
        char *out_suite, size_t out_suite_len);
llc_status llct_sender_respond_pake(llc_sender *s,
        const char *session_id, size_t session_id_len,
        const uint8_t *fp_self, size_t fp_self_len,
        const uint8_t *fp_peer, size_t fp_peer_len,
        const uint8_t *ya, size_t ya_len,
        uint64_t now_ms,
        uint8_t *out_yb, size_t out_yb_len,
        uint8_t *out_tb, size_t out_tb_len);
llc_status llct_sender_verify_confirm(llc_sender *s,
        const char *session_id, size_t session_id_len,
        const uint8_t *ta, size_t ta_len,
        uint64_t now_ms,
        uint8_t *out_ticket, size_t out_ticket_len,
        uint8_t *out_peer_fp, size_t out_peer_fp_len);
llc_status llct_sender_cancel_attempt(llc_sender *s, const char *session_id, size_t session_id_len);
llc_status llct_sender_cancel(llc_sender *s);

llc_status llct_receiver_new(const uint8_t *code, size_t code_len,
                             const uint8_t *rng_script, size_t rng_script_len,
                             llc_receiver **out);
void       llct_receiver_free(llc_receiver *r);
llc_status llct_receiver_begin(llc_receiver *r, llc_attempt **out);
void       llct_attempt_free(llc_attempt *a);
llc_status llct_attempt_nonce_r(llc_attempt *a, uint8_t *out, size_t out_len);
llc_status llct_attempt_suites(llc_attempt *a, char *out, size_t out_len);
llc_status llct_attempt_start(llc_attempt *a,
        const uint8_t *nonce_s, size_t nonce_s_len,
        const char *suite, size_t suite_len,
        const uint8_t *fp_self, size_t fp_self_len,
        const uint8_t *fp_peer, size_t fp_peer_len,
        uint8_t *out_ya, size_t out_ya_len);
llc_status llct_attempt_finish(llc_attempt *a,
        const uint8_t *yb, size_t yb_len,
        const uint8_t *tb, size_t tb_len,
        uint8_t *out_ta, size_t out_ta_len);
/* Same lifetime as llc_attempt_verify_ticket: the attempt answers
   TicketUsed / TicketMismatch after the invite is succeeded and after
   the confirm timer, until llct_attempt_free. */
llc_status llct_attempt_verify_ticket(llc_attempt *a,
        const uint8_t *ticket, size_t ticket_len,
        const uint8_t *fp_client, size_t fp_client_len);

#ifdef __cplusplus
}
#endif
#endif /* LIMLINK_CORE_TESTVECTORS_H */
