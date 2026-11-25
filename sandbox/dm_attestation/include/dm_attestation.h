#ifndef DM_ATTESTATION_H
#define DM_ATTESTATION_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dm_attestation_status {
    char macos_version[64];
    char macos_build[32];
    char hardware_model[64];
    bool sip_enabled;
    bool ssv_sealed;
    bool dc_app_attest_supported;
    bool code_signed;
    bool hardened_runtime;
    bool sandbox_active;
    char code_identifier[256];
    char cdhash_sha256_hex[128];
    char binary_path[1024];
    char binary_sha256_hex[65];
} dm_attestation_status_t;

/* Inspects real macOS security signals (SIP, SSV, DCAppAttest availability, SecCode CDHash/Hardened Runtime, binary SHA-256). Never spoofs or bypasses OS checks. */
bool dm_attestation_collect_status(const char* target_binary_path,
                                   bool sandbox_active,
                                   dm_attestation_status_t* out_status,
                                   char* err_buf,
                                   size_t err_buf_cap);

/* Generates an ephemeral ECDSA P-256 attestation JSON signed with Security.framework (kSecKeyAlgorithmECDSASignatureMessageX962SHA256) bound to nonce_hex. */
bool dm_attestation_sign_challenge(const dm_attestation_status_t* status,
                                   const char* nonce_hex,
                                   char* out_json,
                                   size_t out_json_cap,
                                   char* err_buf,
                                   size_t err_buf_cap);

/* Verifies the ECDSA P-256 signature and ensures claims match payload_canonical with zero tampering. */
bool dm_attestation_verify_bundle(const char* json_bundle,
                                  const char* expected_nonce_hex,
                                  char* err_buf,
                                  size_t err_buf_cap);

#ifdef __cplusplus
}
#endif

#endif /* DM_ATTESTATION_H */
