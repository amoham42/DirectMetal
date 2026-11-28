#include "dm_attestation.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static bool ctest_skip_allowed(void) {
    const char* v = std::getenv("DM_CTEST_ALLOW_SKIP");
    return v && v[0] && std::strcmp(v, "0") != 0;
}

int main(int argc, char** argv) {
    const char* target = (argc >= 2) ? argv[1] : ((argc >= 1) ? argv[0] : nullptr);
    dm_attestation_status_t st{};
    char err[512] = {0};

    if (dm_attestation_collect_status(target, true, nullptr, err, sizeof(err))) {
        fprintf(stderr, "FAIL: dm_attestation_collect_status accepted null out_status\n");
        return 1;
    }

    if (!dm_attestation_collect_status(target, true, &st, err, sizeof(err))) {
        fprintf(stderr, "dm_attestation_collect_status failed: %s\n", err);
        return 1;
    }

    printf("Attestation Status Probe:\n");
    printf("  macOS       : %s (%s)\n", st.macos_version, st.macos_build);
    printf("  Hardware    : %s\n", st.hardware_model);
    printf("  SIP         : %s\n", st.sip_enabled ? "enabled" : "disabled");
    printf("  SSV Sealed  : %s\n", st.ssv_sealed ? "enabled" : "disabled");
    printf("  DCAppAttest : %s (honest macOS capability check)\n", st.dc_app_attest_supported ? "supported" : "false");
    printf("  CodeSigned  : %s (id=%s, hardened=%s)\n",
           st.code_signed ? "yes" : "no",
           st.code_identifier,
           st.hardened_runtime ? "yes" : "no");
    printf("  CDHash      : %s\n", st.cdhash_sha256_hex);
    printf("  BinarySHA256: %s\n", st.binary_sha256_hex);

    if (st.dc_app_attest_supported) {
        fprintf(stderr, "FAIL: DCAppAttestService unexpectedly reported true on macOS\n");
        return 1;
    }
    if (strlen(st.binary_sha256_hex) != 64) {
        fprintf(stderr, "FAIL: Expected 64-char SHA-256 hex\n");
        return 1;
    }

    const char* nonce = "0123456789abcdef0123456789abcdef";
    char json[16384] = {0};
    if (!dm_attestation_sign_challenge(&st, nonce, json, sizeof(json), err, sizeof(err))) {
        fprintf(stderr, "sign_challenge failed: %s\n", err);
        return 1;
    }
    if (!dm_attestation_verify_bundle(json, nonce, err, sizeof(err))) {
        fprintf(stderr, "verify_bundle failed on valid bundle: %s\n", err);
        return 1;
    }
    printf("  [PASS] Valid ECDSA P-256 attestation challenge-response verified.\n");

    /* Tamper test 1: reject wrong expected nonce */
    if (dm_attestation_verify_bundle(json, "deadbeefdeadbeefdeadbeefdeadbeef", err, sizeof(err))) {
        fprintf(stderr, "FAIL: verify_bundle accepted mismatched nonce!\n");
        return 1;
    }
    printf("  [PASS] Mismatched nonce rejected (%s).\n", err);

    /* Tamper test 2: mutate claim inside JSON */
    std::string tampered(json);
    const size_t pos = tampered.find("\"sandbox_active\" : true");
    if (pos == std::string::npos) {
        fprintf(stderr, "FAIL: could not locate sandbox_active in JSON for tamper test\n");
        return 1;
    }
    tampered.replace(pos, strlen("\"sandbox_active\" : true"), "\"sandbox_active\" : false");
    if (dm_attestation_verify_bundle(tampered.c_str(), nonce, err, sizeof(err))) {
        fprintf(stderr, "FAIL: verify_bundle accepted tampered claim!\n");
        return 1;
    }
    printf("  [PASS] Tampered claim rejected (%s).\n", err);

    /* Tamper test 3: mutate canonical payload directly (exercises ECDSA signature rejection & CFError cleanup) */
    std::string sig_tampered(json);
    const size_t npos = sig_tampered.find(nonce);
    if (npos != std::string::npos) {
        sig_tampered[npos] = (sig_tampered[npos] == '0') ? 'f' : '0';
        if (dm_attestation_verify_bundle(sig_tampered.c_str(), nullptr, err, sizeof(err))) {
            fprintf(stderr, "FAIL: verify_bundle accepted corrupted signature/payload!\n");
            return 1;
        }
    }

    /* Tamper test 4: reject malformed JSON types without Objective-C selector exceptions */
    if (dm_attestation_verify_bundle("{\"schema\": 123, \"claims\": []}", nonce, err, sizeof(err))) {
        fprintf(stderr, "FAIL: verify_bundle accepted malformed schema type!\n");
        return 1;
    }
    printf("  [PASS] Malformed JSON types & signature tamper rejected cleanly.\n");

    if (!st.sip_enabled || !st.ssv_sealed) {
        if (ctest_skip_allowed()) {
            printf("[dm_attestation_test] SKIP: host VM has SIP/SSV disabled; cryptographic checks passed.\n");
            return 77;
        }
        fprintf(stderr, "FAIL: Expected SIP and SSV enabled on this Mac\n");
        return 1;
    }

    printf("[dm_attestation_test] PASSED: all platform signals + ECDSA P-256 + tamper checks.\n");
    return 0;
}
