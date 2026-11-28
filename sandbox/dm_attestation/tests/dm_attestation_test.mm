#include "dm_attestation.h"

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <vector>

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_attestation_test] CHECK FAILED (%s:%d): %s\n",        \
                    __FILE__, __LINE__, #expr);                                        \
            std::abort();                                                              \
        }                                                                              \
    } while (0)

static bool is_lowercase_hex(const char* s, size_t expected_len) {
    if (!s || std::strlen(s) != expected_len) return false;
    for (size_t i = 0; i < expected_len; ++i) {
        const char c = s[i];
        const bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!ok) return false;
    }
    return true;
}

static std::string sha256_bytes_hex(const void* data, size_t len) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data, static_cast<CC_LONG>(len), digest);
    char hex[65];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
    }
    hex[64] = '\0';
    return std::string(hex);
}

static NSMutableDictionary* parse_mutable_json(const char* json_str) {
    NSData* raw = [NSData dataWithBytes:json_str length:std::strlen(json_str)];
    NSError* err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:raw
                                             options:NSJSONReadingMutableContainers
                                               error:&err];
    DM_CHECK(obj != nil && [obj isKindOfClass:[NSMutableDictionary class]]);
    return (NSMutableDictionary*)obj;
}

static std::string serialize_json_dict(NSDictionary* dict) {
    NSError* err = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingSortedKeys
                                                     error:&err];
    DM_CHECK(data != nil);
    return std::string(static_cast<const char*>(data.bytes), data.length);
}

static void test_collect_status_edge_cases(void) {
    char err[256];
    std::memset(err, 0x7F, sizeof(err));

    // NULL out_status with normal, NULL/0, and tiny error buffers
    DM_CHECK(!dm_attestation_collect_status(nullptr, true, nullptr, err, sizeof(err)));
    DM_CHECK(std::strlen(err) > 0);
    DM_CHECK(!dm_attestation_collect_status(nullptr, false, nullptr, nullptr, 0));

    char tiny1[2] = {'X', 'Y'};
    DM_CHECK(!dm_attestation_collect_status(nullptr, false, nullptr, tiny1, 1));
    DM_CHECK(tiny1[0] == '\0' && tiny1[1] == 'Y');

    char tiny5[6] = {'A', 'B', 'C', 'D', 'E', 'Z'};
    DM_CHECK(!dm_attestation_collect_status(nullptr, false, nullptr, tiny5, 5));
    DM_CHECK(std::strlen(tiny5) == 4 && tiny5[5] == 'Z');

    // Default self-binary resolution (nullptr and empty string) + poison clearing
    dm_attestation_status_t st_null;
    std::memset(&st_null, 0xFF, sizeof(st_null));
    DM_CHECK(dm_attestation_collect_status(nullptr, false, &st_null, err, sizeof(err)));
    DM_CHECK(!st_null.sandbox_active);
    DM_CHECK(std::strlen(st_null.macos_version) > 0);
    DM_CHECK(std::strlen(st_null.macos_build) > 0);
    DM_CHECK(std::strlen(st_null.hardware_model) > 0);
    DM_CHECK(is_lowercase_hex(st_null.binary_sha256_hex, 64));

    dm_attestation_status_t st_empty{};
    DM_CHECK(dm_attestation_collect_status("", true, &st_empty, nullptr, 0));
    DM_CHECK(st_empty.sandbox_active);
    DM_CHECK(std::strcmp(st_null.binary_sha256_hex, st_empty.binary_sha256_hex) == 0);

    // Nonexistent binary path: must succeed gracefully with empty hash & unsigned status
    dm_attestation_status_t st_missing;
    std::memset(&st_missing, 0xAA, sizeof(st_missing));
    DM_CHECK(dm_attestation_collect_status("/nonexistent/dm_attest_missing_bin_999", true, &st_missing, err, sizeof(err)));
    DM_CHECK(!st_missing.code_signed);
    DM_CHECK(!st_missing.hardened_runtime);
    DM_CHECK(st_missing.binary_sha256_hex[0] == '\0');
    DM_CHECK(st_missing.cdhash_sha256_hex[0] == '\0');
    DM_CHECK(st_missing.code_identifier[0] == '\0');

    // Directory path instead of regular file: fread/EISDIR path must yield empty SHA-256
    dm_attestation_status_t st_dir{};
    DM_CHECK(dm_attestation_collect_status("/tmp", false, &st_dir, err, sizeof(err)));
    DM_CHECK(st_dir.binary_sha256_hex[0] == '\0');
    DM_CHECK(!st_dir.code_signed);

    // Unsigned regular temporary file: exact SHA-256 digest & code_signed == false
    char tmp_path[] = "/tmp/dm_attest_unsigned_XXXXXX";
    const int fd = mkstemp(tmp_path);
    DM_CHECK(fd >= 0);
    const char payload[] = "DirectMetal-Unsigned-Binary-Probe\n";
    DM_CHECK(write(fd, payload, sizeof(payload) - 1) == static_cast<ssize_t>(sizeof(payload) - 1));
    DM_CHECK(close(fd) == 0);

    dm_attestation_status_t st_unsigned{};
    DM_CHECK(dm_attestation_collect_status(tmp_path, false, &st_unsigned, err, sizeof(err)));
    DM_CHECK(unlink(tmp_path) == 0);
    DM_CHECK(!st_unsigned.code_signed);
    const std::string expected_sha = sha256_bytes_hex(payload, sizeof(payload) - 1);
    DM_CHECK(expected_sha == st_unsigned.binary_sha256_hex);

    // Overlong target_binary_path (> sizeof(binary_path) == 1024) must truncate safely
    std::string long_path("/tmp/");
    long_path.append(1400, 'x');
    dm_attestation_status_t st_long{};
    DM_CHECK(dm_attestation_collect_status(long_path.c_str(), false, &st_long, err, sizeof(err)));
    DM_CHECK(std::strlen(st_long.binary_path) == sizeof(st_long.binary_path) - 1);
    DM_CHECK(st_long.binary_sha256_hex[0] == '\0');
}

static void test_sign_challenge_edge_cases(const dm_attestation_status_t& st,
                                           const char* valid_nonce,
                                           size_t valid_bundle_len) {
    char json[16384] = {0};
    char err[256] = {0};

    // NULL pointers and empty/invalid UTF-8 nonces
    DM_CHECK(!dm_attestation_sign_challenge(nullptr, valid_nonce, json, sizeof(json), err, sizeof(err)));
    DM_CHECK(!dm_attestation_sign_challenge(&st, nullptr, json, sizeof(json), err, sizeof(err)));
    DM_CHECK(!dm_attestation_sign_challenge(&st, "", json, sizeof(json), err, sizeof(err)));
    DM_CHECK(!dm_attestation_sign_challenge(&st, "\xff\xfe\x80", json, sizeof(json), err, sizeof(err)));
    DM_CHECK(!dm_attestation_sign_challenge(&st, valid_nonce, nullptr, sizeof(json), err, sizeof(err)));
    DM_CHECK(!dm_attestation_sign_challenge(&st, valid_nonce, nullptr, sizeof(json), nullptr, 0));

    // Undersized output buffers: 0, 1, 511 (pre-check) and 600 (post-serialization check)
    DM_CHECK(!dm_attestation_sign_challenge(&st, valid_nonce, json, 0, err, sizeof(err)));
    DM_CHECK(!dm_attestation_sign_challenge(&st, valid_nonce, json, 1, err, sizeof(err)));
    DM_CHECK(!dm_attestation_sign_challenge(&st, valid_nonce, json, 511, err, sizeof(err)));
    DM_CHECK(!dm_attestation_sign_challenge(&st, valid_nonce, json, 600, err, sizeof(err)));
    DM_CHECK(std::strlen(err) > 0);

    // Tight post-serialization buffer boundary check around valid_bundle_len
    // (Account for +/-4 char Base64 variance from ASN.1 DER P-256 integer padding)
    DM_CHECK(valid_bundle_len > 560);
    const size_t too_small_cap = valid_bundle_len - 16;
    std::vector<char> tight_buf(valid_bundle_len + 32, '\x5A');
    DM_CHECK(!dm_attestation_sign_challenge(&st, valid_nonce, tight_buf.data(), too_small_cap, err, sizeof(err)));
    DM_CHECK(tight_buf[too_small_cap] == '\x5A');  // sentinel past cap untouched

    const size_t fit_cap = valid_bundle_len + 16;
    std::fill(tight_buf.begin(), tight_buf.end(), '\x5A');
    DM_CHECK(dm_attestation_sign_challenge(&st, valid_nonce, tight_buf.data(), fit_cap, err, sizeof(err)));
    const size_t produced_len = std::strlen(tight_buf.data());
    DM_CHECK(produced_len > 0 && produced_len < fit_cap);
    DM_CHECK(tight_buf[produced_len] == '\0');
    DM_CHECK(tight_buf[fit_cap] == '\x5A');  // no write past fit_cap
    DM_CHECK(dm_attestation_verify_bundle(tight_buf.data(), valid_nonce, err, sizeof(err)));

    // Oversized nonce exceeding output buffer capacity must be rejected without overflow
    std::string huge_nonce(20000, 'a');
    std::vector<char> guarded_out(4096 + 8, '\x3C');
    DM_CHECK(!dm_attestation_sign_challenge(&st, huge_nonce.c_str(), guarded_out.data(), 4096, err, sizeof(err)));
    for (size_t i = 4096; i < guarded_out.size(); ++i) {
        DM_CHECK(guarded_out[i] == '\x3C');
    }

    // Large (1024-char) nonce within 16 KiB buffer succeeds and binds strictly
    std::string long_nonce(1024, 'e');
    DM_CHECK(dm_attestation_sign_challenge(&st, long_nonce.c_str(), json, sizeof(json), err, sizeof(err)));
    DM_CHECK(dm_attestation_verify_bundle(json, long_nonce.c_str(), err, sizeof(err)));
    std::string long_nonce_prefix = long_nonce.substr(0, 1023);
    DM_CHECK(!dm_attestation_verify_bundle(json, long_nonce_prefix.c_str(), err, sizeof(err)));
}

static void test_verify_bundle_security_and_tampering(const dm_attestation_status_t& st,
                                                      const char* valid_json,
                                                      const char* nonce) {
    char err[256] = {0};

    // NULL / empty / malformed JSON roots + NULL/tiny err_buf
    DM_CHECK(!dm_attestation_verify_bundle(nullptr, nonce, err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle("", nonce, err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle(nullptr, nonce, nullptr, 0));
    char tiny_err[4] = {'1', '2', '3', '4'};
    DM_CHECK(!dm_attestation_verify_bundle("", nonce, tiny_err, sizeof(tiny_err)));
    DM_CHECK(std::strlen(tiny_err) <= 3);

    DM_CHECK(!dm_attestation_verify_bundle("{", nonce, err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle("[]", nonce, err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle("null", nonce, err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle("\"string\"", nonce, err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle("42", nonce, err, sizeof(err)));

    // Empty / NULL expected_nonce_hex verifies signature + claims without nonce filter
    DM_CHECK(dm_attestation_verify_bundle(valid_json, nullptr, nullptr, 0));
    DM_CHECK(dm_attestation_verify_bundle(valid_json, "", err, sizeof(err)));

    // Nonce mismatch cases: wrong value, truncated, extended, case-flipped, invalid UTF-8
    DM_CHECK(!dm_attestation_verify_bundle(valid_json, "deadbeefdeadbeefdeadbeefdeadbeef", err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle(valid_json, "0123456789abcdef0123456789abcde", err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle(valid_json, "0123456789abcdef0123456789abcdef0", err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle(valid_json, "0123456789ABCDEF0123456789ABCDEF", err, sizeof(err)));
    DM_CHECK(!dm_attestation_verify_bundle(valid_json, "\xff\xfe", err, sizeof(err)));

    // Verify platform claims honestly reflect collected status (headless CI VM safe)
    @autoreleasepool {
        NSMutableDictionary* root = parse_mutable_json(valid_json);
        NSString* keyClass = root[@"key_class"];
        DM_CHECK([keyClass isKindOfClass:[NSString class]]);
        DM_CHECK([keyClass isEqualToString:@"secure-enclave"] ||
                 [keyClass isEqualToString:@"software-ephemeral"]);

        NSDictionary* claims = root[@"claims"];
        DM_CHECK([claims[@"sip_enabled"] boolValue] == st.sip_enabled);
        DM_CHECK([claims[@"ssv_sealed"] boolValue] == st.ssv_sealed);
        DM_CHECK([claims[@"sandbox_active"] boolValue] == st.sandbox_active);

        // Missing each required top-level field must fail verification
        NSArray<NSString*>* requiredFields = @[
            @"schema", @"public_key_x963_b64", @"signature_b64", @"payload_canonical", @"claims"
        ];
        for (NSString* field in requiredFields) {
            NSMutableDictionary* m = parse_mutable_json(valid_json);
            [m removeObjectForKey:field];
            const std::string s = serialize_json_dict(m);
            DM_CHECK(!dm_attestation_verify_bundle(s.c_str(), nonce, err, sizeof(err)));
        }

        // Unsupported schema versions must be rejected
        for (NSString* badSchema in @[@"", @"directmetal.attestation.v0", @"directmetal.attestation.v3"]) {
            NSMutableDictionary* m = parse_mutable_json(valid_json);
            m[@"schema"] = badSchema;
            const std::string s = serialize_json_dict(m);
            DM_CHECK(!dm_attestation_verify_bundle(s.c_str(), nonce, err, sizeof(err)));
        }

        // Corrupted Base64 in public key or signature
        {
            NSMutableDictionary* m = parse_mutable_json(valid_json);
            m[@"public_key_x963_b64"] = @"!!!not-valid-base64!!!";
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(m).c_str(), nonce, err, sizeof(err)));
        }
        {
            NSMutableDictionary* m = parse_mutable_json(valid_json);
            m[@"signature_b64"] = @"***not-valid-base64***";
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(m).c_str(), nonce, err, sizeof(err)));
        }

        // Tampered key_id_sha256 (wrong hash & non-string type)
        {
            NSMutableDictionary* m = parse_mutable_json(valid_json);
            m[@"key_id_sha256"] = @"0000000000000000000000000000000000000000000000000000000000000000";
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(m).c_str(), nonce, err, sizeof(err)));
            m[@"key_id_sha256"] = @12345;
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(m).c_str(), nonce, err, sizeof(err)));
        }

        // Invalid P-256 X9.63 public key bytes WITH matching key_id_sha256 (exercises SecKeyCreateWithData failure)
        {
            uint8_t bad_pub[65] = {0};  // 0x00 prefix is invalid uncompressed X9.63 point
            NSData* badPubData = [NSData dataWithBytes:bad_pub length:sizeof(bad_pub)];
            const std::string bad_kid = sha256_bytes_hex(bad_pub, sizeof(bad_pub));
            NSMutableDictionary* m = parse_mutable_json(valid_json);
            m[@"public_key_x963_b64"] = [badPubData base64EncodedStringWithOptions:0];
            m[@"key_id_sha256"] = [NSString stringWithUTF8String:bad_kid.c_str()];
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(m).c_str(), nonce, err, sizeof(err)));
        }

        // Single-bit flip inside raw decoded ECDSA signature bytes
        {
            NSMutableDictionary* m = parse_mutable_json(valid_json);
            NSData* origSig = [[NSData alloc] initWithBase64EncodedString:m[@"signature_b64"] options:0];
            DM_CHECK(origSig != nil && origSig.length > 8);
            NSMutableData* mutSig = [origSig mutableCopy];
            uint8_t* bytes = static_cast<uint8_t*>(mutSig.mutableBytes);
            bytes[mutSig.length - 2] ^= 0x01;
            m[@"signature_b64"] = [mutSig base64EncodedStringWithOptions:0];
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(m).c_str(), nonce, err, sizeof(err)));
        }

        // Claims dictionary desynchronization (injected key & modified claim)
        {
            NSMutableDictionary* m = parse_mutable_json(valid_json);
            NSMutableDictionary* mutClaims = [m[@"claims"] mutableCopy];
            mutClaims[@"sandbox_active"] = @(![mutClaims[@"sandbox_active"] boolValue]);
            m[@"claims"] = mutClaims;
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(m).c_str(), nonce, err, sizeof(err)));

            NSMutableDictionary* injClaims = [root[@"claims"] mutableCopy];
            injClaims[@"injected_claim"] = @"evil";
            m[@"claims"] = injClaims;
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(m).c_str(), nonce, err, sizeof(err)));
        }

        // Cross-bundle public-key transplant attack (valid key B + valid sig A)
        {
            char other_json[16384] = {0};
            DM_CHECK(dm_attestation_sign_challenge(&st, "fedcba9876543210fedcba9876543210",
                                                   other_json, sizeof(other_json), err, sizeof(err)));
            NSMutableDictionary* mA = parse_mutable_json(valid_json);
            NSMutableDictionary* mB = parse_mutable_json(other_json);
            mA[@"public_key_x963_b64"] = mB[@"public_key_x963_b64"];
            mA[@"key_id_sha256"] = mB[@"key_id_sha256"];
            DM_CHECK(!dm_attestation_verify_bundle(serialize_json_dict(mA).c_str(), nonce, err, sizeof(err)));
        }
    }

    // Malformed JSON field types must not raise Objective-C selector exceptions
    DM_CHECK(!dm_attestation_verify_bundle("{\"schema\": 123, \"claims\": []}", nonce, err, sizeof(err)));
}

static void test_repeated_collect_sign_verify_cycles(const char* target) {
    dm_attestation_status_t base_st{};
    char base_err[256] = {0};
    // Repeated status collection cycles (exercises NSTask pipes, sysctl, SecStaticCode & SHA-256)
    for (int c = 0; c < 4; ++c) {
        @autoreleasepool {
            DM_CHECK(dm_attestation_collect_status(target, (c % 2 == 0), &base_st, base_err, sizeof(base_err)));
            DM_CHECK(base_st.sandbox_active == (c % 2 == 0));
            DM_CHECK(is_lowercase_hex(base_st.binary_sha256_hex, 64));
        }
    }

    // Repeated ephemeral ECDSA P-256 sign/verify cycles (checks SecKey/CFError cleanup & key rotation)
    std::string prev_key_id;
    for (int i = 0; i < 16; ++i) {
        @autoreleasepool {
            char err[256] = {0};
            char json[16384] = {0};
            char nonce[65];
            snprintf(nonce, sizeof(nonce), "%016x%016x",
                     static_cast<unsigned>(i + 1),
                     0x9e3779b9u * static_cast<unsigned>(i + 1));

            DM_CHECK(dm_attestation_sign_challenge(&base_st, nonce, json, sizeof(json), err, sizeof(err)));
            DM_CHECK(dm_attestation_verify_bundle(json, nonce, err, sizeof(err)));
            DM_CHECK(!dm_attestation_verify_bundle(json, "00000000000000000000000000000000", err, sizeof(err)));

            NSMutableDictionary* parsed = parse_mutable_json(json);
            NSString* kid = parsed[@"key_id_sha256"];
            DM_CHECK([kid isKindOfClass:[NSString class]] && kid.length == 64);
            const std::string cur_key_id(kid.UTF8String);
            if (!prev_key_id.empty()) {
                DM_CHECK(cur_key_id != prev_key_id);  // ephemeral key rotated every call
            }
            prev_key_id = cur_key_id;
        }
    }
}

int main(int argc, char** argv) {
    const char* target = (argc >= 2) ? argv[1] : ((argc >= 1) ? argv[0] : nullptr);
    dm_attestation_status_t st{};
    char err[512] = {0};

    test_collect_status_edge_cases();

    DM_CHECK(dm_attestation_collect_status(target, true, &st, err, sizeof(err)));

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

    DM_CHECK(!st.dc_app_attest_supported);
    DM_CHECK(is_lowercase_hex(st.binary_sha256_hex, 64));

    const char* nonce = "0123456789abcdef0123456789abcdef";
    char json[16384] = {0};
    DM_CHECK(dm_attestation_sign_challenge(&st, nonce, json, sizeof(json), err, sizeof(err)));
    DM_CHECK(dm_attestation_verify_bundle(json, nonce, err, sizeof(err)));
    printf("  [PASS] Valid ECDSA P-256 attestation challenge-response verified.\n");

    test_sign_challenge_edge_cases(st, nonce, std::strlen(json));
    printf("  [PASS] NULL, undersized buffer, exact NUL-boundary & oversized/empty nonce checks.\n");

    test_verify_bundle_security_and_tampering(st, json, nonce);
    printf("  [PASS] Tampered claims, bit-flipped signature, key transplant & schema checks.\n");

    test_repeated_collect_sign_verify_cycles(target);
    printf("  [PASS] 16 repeated collect/sign/verify ephemeral key cycles completed cleanly.\n");

    if (!st.sip_enabled || !st.ssv_sealed) {
        printf("[dm_attestation_test] PASSED (headless/VM mode: SIP=%s, SSV=%s honestly attested; all cryptographic & security checks passed).\n",
               st.sip_enabled ? "enabled" : "disabled",
               st.ssv_sealed ? "enabled" : "disabled");
        return 0;
    }

    printf("[dm_attestation_test] PASSED: all platform signals + ECDSA P-256 + tamper checks.\n");
    return 0;
}
