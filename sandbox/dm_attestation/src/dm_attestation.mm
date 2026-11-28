#import <CommonCrypto/CommonDigest.h>
#import <DeviceCheck/DeviceCheck.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>

#include "dm_attestation.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

static void set_err(char* buf, size_t cap, const char* msg) {
    if (buf && cap > 0) {
        snprintf(buf, cap, "%s", msg ? msg : "unknown error");
    }
}

static void consume_cferror(CFErrorRef* cfErr, char* err_buf, size_t err_cap, const char* fallback) {
    const char* msg = fallback;
    NSError* nsErr = nil;
    if (cfErr && *cfErr) {
        nsErr = (__bridge_transfer NSError*)(*cfErr);
        *cfErr = nullptr;
        if (nsErr.localizedDescription && nsErr.localizedDescription.UTF8String) {
            msg = nsErr.localizedDescription.UTF8String;
        }
    }
    set_err(err_buf, err_cap, msg);
}

static NSString* safe_utf8_nsstring(const char* s) {
    if (!s) return @"";
    NSString* ns = [NSString stringWithUTF8String:s];
    return ns ?: @"";
}

static void read_sysctl_str(const char* name, char* out, size_t cap) {
    if (!name || !out || cap == 0) return;
    memset(out, 0, cap);
    size_t sz = cap - 1;
    if (sysctlbyname(name, out, &sz, nullptr, 0) == 0) {
        out[cap - 1] = '\0';
    } else {
        out[0] = '\0';
    }
}

static NSString* run_capture_stdout(NSString* launchPath, NSArray<NSString*>* args, int* outStatus = nullptr) {
    if (!launchPath || launchPath.length == 0) {
        if (outStatus) *outStatus = -1;
        return nil;
    }
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:launchPath];
    task.arguments = args ?: @[];
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError* err = nil;
    if (![task launchAndReturnError:&err]) {
        if (outStatus) *outStatus = -1;
        return nil;
    }
    // Drain pipe BEFORE waitUntilExit to avoid 64 KiB pipe buffer deadlocks.
    NSData* data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    if (outStatus) *outStatus = task.terminationStatus;
    if (!data || data.length == 0) return @"";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static bool sha256_file_hex(const char* path, char out_hex[65]) {
    if (!out_hex) return false;
    out_hex[0] = '\0';
    if (!path || !path[0]) return false;
    FILE* fp = fopen(path, "rb");
    if (!fp) return false;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buf[65536];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
        CC_SHA256_Update(&ctx, buf, static_cast<CC_LONG>(n));
    }
    const bool io_err = ferror(fp) != 0;
    fclose(fp);
    if (io_err) {
        return false;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        snprintf(out_hex + i * 2, 3, "%02x", digest[i]);
    }
    out_hex[64] = '\0';
    return true;
}

static NSString* hex_from_nsdata(NSData* data) {
    if (!data || data.length == 0) return @"";
    const uint8_t* bytes = static_cast<const uint8_t*>(data.bytes);
    if (!bytes) return @"";
    NSMutableString* hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; ++i) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

static NSString* sha256_hex_nsdata(NSData* data) {
    if (!data) return @"";
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    const void* ptr = (data.length > 0 && data.bytes) ? data.bytes : "";
    CC_SHA256(ptr, static_cast<CC_LONG>(data.length), digest);
    NSMutableString* hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

bool dm_attestation_collect_status(const char* target_binary_path,
                                   bool sandbox_active,
                                   dm_attestation_status_t* out_status,
                                   char* err_buf,
                                   size_t err_buf_cap) {
    if (err_buf && err_buf_cap > 0) {
        err_buf[0] = '\0';
    }
    if (!out_status) {
        set_err(err_buf, err_buf_cap, "null out_status");
        return false;
    }
    memset(out_status, 0, sizeof(*out_status));
    out_status->sandbox_active = sandbox_active;

    @autoreleasepool {
        NSOperatingSystemVersion osv = [[NSProcessInfo processInfo] operatingSystemVersion];
        snprintf(out_status->macos_version, sizeof(out_status->macos_version),
                 "%ld.%ld.%ld",
                 static_cast<long>(osv.majorVersion),
                 static_cast<long>(osv.minorVersion),
                 static_cast<long>(osv.patchVersion));
        read_sysctl_str("kern.osversion", out_status->macos_build, sizeof(out_status->macos_build));
        read_sysctl_str("hw.model", out_status->hardware_model, sizeof(out_status->hardware_model));

        /* Real OS integrity signals (never spoofed) */
        int csrRc = -1;
        NSString* csrOut = run_capture_stdout(@"/usr/bin/csrutil", @[@"status"], &csrRc);
        if (csrRc == 0 && csrOut) {
            out_status->sip_enabled = [csrOut containsString:@"enabled"];
        }
        int ssvRc = -1;
        NSString* ssvOut = run_capture_stdout(@"/usr/bin/csrutil", @[@"authenticated-root", @"status"], &ssvRc);
        if (ssvRc == 0 && ssvOut) {
            out_status->ssv_sealed = [ssvOut containsString:@"enabled"];
        }

        /* Query Apple DCAppAttestService honestly (false on macOS desktop targets) */
        out_status->dc_app_attest_supported = [[DCAppAttestService sharedService] isSupported];

        /* Determine target executable path */
        char resolved_bin[1024] = {0};
        if (target_binary_path && target_binary_path[0]) {
            if (!realpath(target_binary_path, resolved_bin)) {
                snprintf(resolved_bin, sizeof(resolved_bin), "%s", target_binary_path);
            }
        } else {
            uint32_t sz = sizeof(resolved_bin);
            char raw_self[1024] = {0};
            if (_NSGetExecutablePath(raw_self, &sz) == 0) {
                if (!realpath(raw_self, resolved_bin)) {
                    snprintf(resolved_bin, sizeof(resolved_bin), "%s", raw_self);
                }
            }
        }
        snprintf(out_status->binary_path, sizeof(out_status->binary_path), "%s", resolved_bin);
        if (resolved_bin[0]) {
            sha256_file_hex(resolved_bin, out_status->binary_sha256_hex);

            /* SecStaticCode validation & CDHash inspection */
            NSString* binPathStr = [NSString stringWithUTF8String:resolved_bin];
            NSURL* url = (binPathStr && binPathStr.length > 0) ? [NSURL fileURLWithPath:binPathStr] : nil;
            SecStaticCodeRef staticCode = nullptr;
            if (url && SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &staticCode) == errSecSuccess && staticCode) {
                const OSStatus valStatus = SecStaticCodeCheckValidity(staticCode, kSecCSDefaultFlags, nullptr);
                CFDictionaryRef info = nullptr;
                if (SecCodeCopySigningInformation(staticCode,
                                                  static_cast<SecCSFlags>(kSecCSSigningInformation | kSecCSRequirementInformation),
                                                  &info) == errSecSuccess && info) {
                    NSDictionary* dict = (__bridge NSDictionary*)info;
                    NSString* ident = dict[(__bridge NSString*)kSecCodeInfoIdentifier];
                    if ([ident isKindOfClass:[NSString class]] && ident.UTF8String && valStatus == errSecSuccess) {
                        out_status->code_signed = true;
                        snprintf(out_status->code_identifier, sizeof(out_status->code_identifier), "%s", ident.UTF8String);
                    }
                    NSNumber* flagsNum = dict[(__bridge NSString*)kSecCodeInfoFlags];
                    if ([flagsNum isKindOfClass:[NSNumber class]]) {
                        const uint32_t flags = flagsNum.unsignedIntValue;
                        out_status->hardened_runtime = (flags & kSecCodeSignatureRuntime) != 0;
                    }
                    NSData* cdhash = dict[(__bridge NSString*)kSecCodeInfoUnique];
                    if ([cdhash isKindOfClass:[NSData class]]) {
                        NSString* hex = hex_from_nsdata(cdhash);
                        if (hex.UTF8String) {
                            snprintf(out_status->cdhash_sha256_hex, sizeof(out_status->cdhash_sha256_hex), "%s", hex.UTF8String);
                        }
                    }
                    CFRelease(info);
                }
                CFRelease(staticCode);
            }
        }
        return true;
    }
}

bool dm_attestation_sign_challenge(const dm_attestation_status_t* status,
                                   const char* nonce_hex,
                                   char* out_json,
                                   size_t out_json_cap,
                                   char* err_buf,
                                   size_t err_buf_cap) {
    if (err_buf && err_buf_cap > 0) {
        err_buf[0] = '\0';
    }
    if (!status || !nonce_hex || !nonce_hex[0] || !out_json || out_json_cap < 512) {
        set_err(err_buf, err_buf_cap, "invalid arguments to sign_challenge");
        return false;
    }

    @autoreleasepool {
        NSString* nsNonce = [NSString stringWithUTF8String:nonce_hex];
        if (!nsNonce || nsNonce.length == 0) {
            set_err(err_buf, err_buf_cap, "invalid UTF-8 in nonce_hex");
            return false;
        }

        NSDictionary* keyAttrs = nil;
        NSString* keyClass = @"software-ephemeral";
        CFErrorRef cfErr = nullptr;
        SecKeyRef privKey = nullptr;

        /* Prefer Apple Silicon hardware Secure Enclave P-256 non-exportable signing key */
        SecAccessControlRef seAccess = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAccessControlPrivateKeyUsage,
            &cfErr);
        if (cfErr) {
            CFRelease(cfErr);
            cfErr = nullptr;
        }
        if (seAccess) {
            NSDictionary* seAttrs = @{
                (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                (__bridge id)kSecAttrKeySizeInBits: @256,
                (__bridge id)kSecAttrTokenID: (__bridge id)kSecAttrTokenIDSecureEnclave,
                (__bridge id)kSecPrivateKeyAttrs: @{
                    (__bridge id)kSecAttrIsPermanent: @NO,
                    (__bridge id)kSecAttrAccessControl: (__bridge id)seAccess,
                },
            };
            privKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)seAttrs, &cfErr);
            CFRelease(seAccess);
            if (privKey) {
                keyClass = @"secure-enclave";
            } else if (cfErr) {
                CFRelease(cfErr);
                cfErr = nullptr;
            }
        }
        if (!privKey) {
            keyAttrs = @{
                (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                (__bridge id)kSecAttrKeySizeInBits: @256,
                (__bridge id)kSecAttrIsPermanent: @NO,
            };
            privKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)keyAttrs, &cfErr);
        }
        if (!privKey) {
            consume_cferror(&cfErr, err_buf, err_buf_cap, "SecKeyCreateRandomKey failed");
            return false;
        }
        SecKeyRef pubKey = SecKeyCopyPublicKey(privKey);
        if (!pubKey) {
            CFRelease(privKey);
            set_err(err_buf, err_buf_cap, "SecKeyCopyPublicKey failed");
            return false;
        }
        cfErr = nullptr;
        NSData* pubRaw = (__bridge_transfer NSData*)SecKeyCopyExternalRepresentation(pubKey, &cfErr);
        CFRelease(pubKey);
        if (!pubRaw) {
            CFRelease(privKey);
            consume_cferror(&cfErr, err_buf, err_buf_cap, "SecKeyCopyExternalRepresentation failed");
            return false;
        }

        NSISO8601DateFormatter* isoFmt = [[NSISO8601DateFormatter alloc] init];
        NSString* ts = [isoFmt stringFromDate:[NSDate date]];

        char boot_uuid[128] = {0};
        read_sysctl_str("kern.bootsessionuuid", boot_uuid, sizeof(boot_uuid));
        BOOL dcDeviceSupported = [[DCDevice currentDevice] isSupported];
        uint32_t dyldCount = _dyld_image_count();

        NSDictionary* claims = @{
            @"nonce": nsNonce,
            @"timestamp_utc": ts ?: @"",
            @"macos_version": safe_utf8_nsstring(status->macos_version),
            @"macos_build": safe_utf8_nsstring(status->macos_build),
            @"hardware_model": safe_utf8_nsstring(status->hardware_model),
            @"boot_session_uuid": safe_utf8_nsstring(boot_uuid),
            @"sip_enabled": @(status->sip_enabled),
            @"ssv_sealed": @(status->ssv_sealed),
            @"dc_device_supported": @(dcDeviceSupported),
            @"dc_app_attest_supported": @(status->dc_app_attest_supported),
            @"dyld_image_count": @(dyldCount),
            @"code_signed": @(status->code_signed),
            @"hardened_runtime": @(status->hardened_runtime),
            @"sandbox_active": @(status->sandbox_active),
            @"code_identifier": safe_utf8_nsstring(status->code_identifier),
            @"cdhash": safe_utf8_nsstring(status->cdhash_sha256_hex),
            @"binary_sha256": safe_utf8_nsstring(status->binary_sha256_hex),
        };

        NSError* jsonErr = nil;
        NSData* canonicalData = [NSJSONSerialization dataWithJSONObject:claims
                                                                options:NSJSONWritingSortedKeys
                                                                  error:&jsonErr];
        if (!canonicalData) {
            CFRelease(privKey);
            const char* jmsg = (jsonErr && jsonErr.localizedDescription) ? jsonErr.localizedDescription.UTF8String : nullptr;
            set_err(err_buf, err_buf_cap, jmsg ? jmsg : "JSON encode failed");
            return false;
        }
        NSString* canonicalStr = [[NSString alloc] initWithData:canonicalData encoding:NSUTF8StringEncoding];
        if (!canonicalStr) {
            CFRelease(privKey);
            set_err(err_buf, err_buf_cap, "canonical payload UTF-8 conversion failed");
            return false;
        }

        cfErr = nullptr;
        NSData* sig = (__bridge_transfer NSData*)SecKeyCreateSignature(
            privKey,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)canonicalData,
            &cfErr);
        CFRelease(privKey);
        if (!sig) {
            consume_cferror(&cfErr, err_buf, err_buf_cap, "SecKeyCreateSignature failed");
            return false;
        }

        NSDictionary* bundle = @{
            @"schema": @"directmetal.attestation.v2",
            @"algorithm": @"ECDSA-P256-SHA256-X962",
            @"key_class": keyClass,
            @"public_key_x963_b64": [pubRaw base64EncodedStringWithOptions:0] ?: @"",
            @"key_id_sha256": sha256_hex_nsdata(pubRaw),
            @"signature_b64": [sig base64EncodedStringWithOptions:0] ?: @"",
            @"payload_canonical": canonicalStr,
            @"claims": claims,
        };
        NSData* bundleData = [NSJSONSerialization dataWithJSONObject:bundle
                                                             options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                               error:&jsonErr];
        if (!bundleData || bundleData.length + 1 > out_json_cap) {
            set_err(err_buf, err_buf_cap, "bundle serialization failed or buffer too small");
            return false;
        }
        memcpy(out_json, bundleData.bytes, bundleData.length);
        out_json[bundleData.length] = '\0';
        return true;
    }
}

bool dm_attestation_verify_bundle(const char* json_bundle,
                                  const char* expected_nonce_hex,
                                  char* err_buf,
                                  size_t err_buf_cap) {
    if (err_buf && err_buf_cap > 0) {
        err_buf[0] = '\0';
    }
    if (!json_bundle || !json_bundle[0]) {
        set_err(err_buf, err_buf_cap, "empty bundle");
        return false;
    }

    @autoreleasepool {
        NSData* raw = [NSData dataWithBytes:json_bundle length:strlen(json_bundle)];
        NSError* jsonErr = nil;
        NSDictionary* bundle = [NSJSONSerialization JSONObjectWithData:raw options:0 error:&jsonErr];
        if (![bundle isKindOfClass:[NSDictionary class]]) {
            set_err(err_buf, err_buf_cap, "invalid JSON root");
            return false;
        }
        id schemaObj = bundle[@"schema"];
        id pubB64Obj = bundle[@"public_key_x963_b64"];
        id keyIdObj = bundle[@"key_id_sha256"];
        id sigB64Obj = bundle[@"signature_b64"];
        id canonicalObj = bundle[@"payload_canonical"];
        id claimsObj = bundle[@"claims"];
        if (![schemaObj isKindOfClass:[NSString class]] ||
            ![pubB64Obj isKindOfClass:[NSString class]] ||
            ![sigB64Obj isKindOfClass:[NSString class]] ||
            ![canonicalObj isKindOfClass:[NSString class]] ||
            ![claimsObj isKindOfClass:[NSDictionary class]]) {
            set_err(err_buf, err_buf_cap, "missing or invalid required bundle fields");
            return false;
        }

        NSString* schema = (NSString*)schemaObj;
        NSString* pubB64 = (NSString*)pubB64Obj;
        NSString* sigB64 = (NSString*)sigB64Obj;
        NSString* canonical = (NSString*)canonicalObj;
        NSDictionary* claims = (NSDictionary*)claimsObj;
        if (![schema isEqualToString:@"directmetal.attestation.v1"] &&
            ![schema isEqualToString:@"directmetal.attestation.v2"]) {
            set_err(err_buf, err_buf_cap, "unsupported attestation schema");
            return false;
        }

        NSData* pubData = [[NSData alloc] initWithBase64EncodedString:pubB64 options:0];
        NSData* sigData = [[NSData alloc] initWithBase64EncodedString:sigB64 options:0];
        NSData* payloadData = [canonical dataUsingEncoding:NSUTF8StringEncoding];
        if (!pubData || pubData.length == 0 || !sigData || sigData.length == 0 || !payloadData) {
            set_err(err_buf, err_buf_cap, "base64/UTF-8 decode failed");
            return false;
        }
        if (keyIdObj != nil) {
            if (![keyIdObj isKindOfClass:[NSString class]] ||
                ![sha256_hex_nsdata(pubData) isEqualToString:(NSString*)keyIdObj]) {
                set_err(err_buf, err_buf_cap, "key_id_sha256 mismatch");
                return false;
            }
        }

        /* Ensure claims dictionary inside bundle matches signed payload_canonical exactly */
        NSDictionary* signedClaims = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:&jsonErr];
        if (![signedClaims isKindOfClass:[NSDictionary class]] || ![signedClaims isEqualToDictionary:claims]) {
            set_err(err_buf, err_buf_cap, "claims dictionary differs from signed payload_canonical");
            return false;
        }
        if (expected_nonce_hex && expected_nonce_hex[0]) {
            NSString* expNonce = [NSString stringWithUTF8String:expected_nonce_hex];
            id gotNonceObj = signedClaims[@"nonce"];
            if (!expNonce || ![gotNonceObj isKindOfClass:[NSString class]] ||
                ![(NSString*)gotNonceObj isEqualToString:expNonce]) {
                set_err(err_buf, err_buf_cap, "nonce mismatch");
                return false;
            }
        }

        NSDictionary* pubAttrs = @{
            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
            (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
            (__bridge id)kSecAttrKeySizeInBits: @256,
        };
        CFErrorRef cfErr = nullptr;
        SecKeyRef pubKey = SecKeyCreateWithData((__bridge CFDataRef)pubData,
                                                (__bridge CFDictionaryRef)pubAttrs,
                                                &cfErr);
        if (!pubKey) {
            consume_cferror(&cfErr, err_buf, err_buf_cap, "SecKeyCreateWithData failed");
            return false;
        }
        const Boolean ok = SecKeyVerifySignature(
            pubKey,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)payloadData,
            (__bridge CFDataRef)sigData,
            &cfErr);
        CFRelease(pubKey);
        if (!ok) {
            consume_cferror(&cfErr, err_buf, err_buf_cap, "ECDSA signature verification failed");
            return false;
        }
        if (cfErr) {
            CFRelease(cfErr);
        }
        return true;
    }
}
