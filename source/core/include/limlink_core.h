/* limlink_core.h  ——  LimLink 共用 Rust 核心的 C 接口，ABI 版本 1 */
#ifndef LIMLINK_CORE_H
#define LIMLINK_CORE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define LLC_ABI_VERSION 1u

/* 定长字节（CPACE-RISTR255-SHA512，15.10.7 的长度表） */
#define LLC_FP_LEN              32   /* 指纹原始字节 */
#define LLC_NONCE_LEN           16   /* nonceR / nonceS */
#define LLC_POINT_LEN           32   /* Ya / Yb */
#define LLC_TAG_LEN             64   /* Ta / Tb */
#define LLC_TICKET_LEN          32   /* inviteTicket */
#define LLC_CODE_LEN             6   /* 6 位码，ASCII '0'..'9' */
#define LLC_SESSION_ID_LEN      22   /* inviteSessionId，base64url 文本 */
/* 文本输出缓冲区的最小长度（含结尾 0） */
#define LLC_CODE_BUF_LEN         7
#define LLC_SESSION_ID_BUF_LEN  23
#define LLC_SUITE_BUF_LEN       64
#define LLC_SUITES_BUF_LEN     256
#define LLC_VERSION_BUF_LEN     64

/* 返回值：0 成功；1–14 跟 CoreError 一一对应；100 起只在 C 接口里有 */
typedef int32_t llc_status;
#define LLC_OK                         0
#define LLC_ERR_CODE_FORMAT            1
#define LLC_ERR_SUITE_UNSUPPORTED      2
#define LLC_ERR_EXPIRED                3
#define LLC_ERR_EXHAUSTED              4
#define LLC_ERR_BUSY                   5
#define LLC_ERR_NOT_ACTIVE             6
#define LLC_ERR_UNKNOWN_ATTEMPT        7
#define LLC_ERR_INVALID_PEER_MESSAGE   8
#define LLC_ERR_CONFIRM_MISMATCH       9
#define LLC_ERR_TAG_MISMATCH          10
#define LLC_ERR_TICKET_MISMATCH       11
#define LLC_ERR_BAD_STATE             12
#define LLC_ERR_RNG                   13
#define LLC_ERR_TICKET_USED           14   /* 票据和指纹都对，但这张票据已经用过 */
#define LLC_ERR_NULL_ARG             100   /* 必填指针是空的 */
#define LLC_ERR_BUFFER_LEN           101   /* 输入长度或输出缓冲区长度不对 */
#define LLC_ERR_PANIC                102   /* 核心内部 panic，已拦下 */

/* InviteStatus.state */
#define LLC_STATE_WAITING      0
#define LLC_STATE_IN_PROGRESS  1
#define LLC_STATE_SUCCEEDED    2
#define LLC_STATE_EXHAUSTED    3
#define LLC_STATE_EXPIRED      4
#define LLC_STATE_CANCELLED    5

typedef struct llc_invite_status {   /* 共 24 字节，没有填充 */
    int32_t  state;                  /* LLC_STATE_* */
    uint32_t failures;
    uint32_t attempts_left;
    uint32_t reserved;               /* 现在写 0，调用方不读 */
    uint64_t expires_in_ms;
} llc_invite_status;

/* 不透明对象 */
typedef struct llc_sender   llc_sender;    /* InviteSender */
typedef struct llc_receiver llc_receiver;  /* InviteReceiver */
typedef struct llc_attempt  llc_attempt;   /* ReceiverAttempt */

/* ---- 公共 ---- */
uint32_t   llc_abi_version(void);
llc_status llc_core_info(char *out_version, size_t out_version_len,   /* >= LLC_VERSION_BUF_LEN */
                         char *out_suites,  size_t out_suites_len);   /* >= LLC_SUITES_BUF_LEN，逗号分隔 */

/* ---- 发送方 ---- */
llc_status llc_sender_new(uint64_t now_ms, llc_sender **out);
void       llc_sender_free(llc_sender *s);
llc_status llc_sender_code(llc_sender *s, char *out, size_t out_len);   /* >= LLC_CODE_BUF_LEN；终态后写空串 */
llc_status llc_sender_status(llc_sender *s, uint64_t now_ms, llc_invite_status *out);
llc_status llc_sender_accept_hello(llc_sender *s,
        const uint8_t *nonce_r, size_t nonce_r_len,            /* LLC_NONCE_LEN */
        const char *peer_suites, size_t peer_suites_len,       /* 逗号分隔 ASCII */
        uint64_t now_ms,
        char *out_session_id, size_t out_session_id_len,       /* >= LLC_SESSION_ID_BUF_LEN */
        uint8_t *out_nonce_s, size_t out_nonce_s_len,          /* LLC_NONCE_LEN */
        char *out_suite, size_t out_suite_len);                /* >= LLC_SUITE_BUF_LEN */
llc_status llc_sender_respond_pake(llc_sender *s,
        const char *session_id, size_t session_id_len,         /* LLC_SESSION_ID_LEN */
        const uint8_t *fp_self, size_t fp_self_len,            /* LLC_FP_LEN */
        const uint8_t *fp_peer, size_t fp_peer_len,            /* LLC_FP_LEN */
        const uint8_t *ya, size_t ya_len,                      /* LLC_POINT_LEN */
        uint64_t now_ms,
        uint8_t *out_yb, size_t out_yb_len,                    /* LLC_POINT_LEN */
        uint8_t *out_tb, size_t out_tb_len);                   /* LLC_TAG_LEN */
llc_status llc_sender_verify_confirm(llc_sender *s,
        const char *session_id, size_t session_id_len,
        const uint8_t *ta, size_t ta_len,                      /* LLC_TAG_LEN */
        uint64_t now_ms,
        uint8_t *out_ticket, size_t out_ticket_len,            /* LLC_TICKET_LEN */
        uint8_t *out_peer_fp, size_t out_peer_fp_len);         /* LLC_FP_LEN */
llc_status llc_sender_cancel_attempt(llc_sender *s, const char *session_id, size_t session_id_len);
llc_status llc_sender_cancel(llc_sender *s);

/* ---- 接收方 ---- */
llc_status llc_receiver_new(const uint8_t *code, size_t code_len,     /* LLC_CODE_LEN，已转半角、去空格 */
                            llc_receiver **out);
void       llc_receiver_free(llc_receiver *r);
llc_status llc_receiver_begin(llc_receiver *r, llc_attempt **out);
void       llc_attempt_free(llc_attempt *a);
llc_status llc_attempt_nonce_r(llc_attempt *a, uint8_t *out, size_t out_len);   /* LLC_NONCE_LEN */
llc_status llc_attempt_suites(llc_attempt *a, char *out, size_t out_len);       /* >= LLC_SUITES_BUF_LEN */
llc_status llc_attempt_start(llc_attempt *a,
        const uint8_t *nonce_s, size_t nonce_s_len,
        const char *suite, size_t suite_len,
        const uint8_t *fp_self, size_t fp_self_len,
        const uint8_t *fp_peer, size_t fp_peer_len,
        uint8_t *out_ya, size_t out_ya_len);
llc_status llc_attempt_finish(llc_attempt *a,
        const uint8_t *yb, size_t yb_len,
        const uint8_t *tb, size_t tb_len,
        uint8_t *out_ta, size_t out_ta_len);
/* 核销挂在这次 llc_attempt 上，不看发送方邀请是否已经 succeeded，也不看 30 秒确认计时。
   平台把 attempt 留到第一场会话结束。finish 成功之后一直可以调用，直到 llc_attempt_free：
   票据和 fp_client 都对、且还没消费过 → OK，并记成已消费；对不上 → TICKET_MISMATCH，不消费。
   已经消费过：两者都与第一次成功相同 → TICKET_USED，否则 TICKET_MISMATCH。
   上面几种结果都不会变成 BAD_STATE 或 UNKNOWN_ATTEMPT。释放 attempt 之后核心不再管这次核销。 */
llc_status llc_attempt_verify_ticket(llc_attempt *a,
        const uint8_t *ticket, size_t ticket_len,
        const uint8_t *fp_client, size_t fp_client_len);

#ifdef __cplusplus
}
#endif
#endif /* LIMLINK_CORE_H */
