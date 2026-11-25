#import <CommonCrypto/CommonDigest.h>
#import <DeviceCheck/DeviceCheck.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <mach-o/dyld.h>
#import <sys/sysctl.h>

#include "dm_attestation.h"

#include <cstdio>
#include <cstring>

static void set_err(char* buf, size_t cap, const char* msg) {
    if (buf && cap > 0) {
        snprintf(buf, cap, "%s", msg ? msg : "unknown error");
    }
}

static void read_sysctl_str(const char* name, char* out, size_t cap) {
    if (!out || cap == 0) return;
    out[0] = '\0';
    size_t sz = cap - 1;
    if (sysctlbyname(name, out, &sz, nullptr, 0) == 0) {
        out[cap - 1] = '\0';
    }
}

static NSString* run_capture_stdout(NSString* launchPath, NSArray<NSString*>* args, int* outStatus = nullptr) {
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:launchPath];
    task.arguments = args;
    NSPipe* pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError* err = nil;
    if (![task launchAndReturnError:&err]) {
        if (outStatus) *outStatus = -1;
        return nil;
    }
    [task waitUntilExit];
    if (outStatus) *outStatus = task.terminationStatus;
    NSData* data = [[pipe fileHandleForReading] readDataToEndOfFile];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static bool sha256_file_hex(const char* path, char out_hex[65]) {
    out_hex[0] = '\0';
    FILE* fp = fopen(path, "rb");
    if (!fp) return false;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buf[65536];
    size_t n = 0;
    while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) {
        CC_SHA256_Update(&ctx, buf, static_cast<CC_LONG>(n));
    }
    fclose(fp);
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
    NSMutableString* hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; ++i) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

static NSString* sha256_hex_nsdata(NSData* data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, static_cast<CC_LONG>(data.length), digest);
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
        }

        /* SecStaticCode validation & CDHash inspection */
        SecStaticCodeRef staticCode = nullptr;
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:resolved_bin]];
        if (url && SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &staticCode) == errSecSuccess) {
            const OSStatus valStatus = SecStaticCodeCheckValidity(staticCode, kSecCSDefaultFlags, nullptr);
            CFDictionaryRef info = nullptr;
            if (SecCodeCopySigningInformation(staticCode,
                                              static_cast<SecCSFlags>(kSecCSSigningInformation | kSecCSRequirementInformation),
                                              &info) == errSecSuccess && info) {
                NSDictionary* dict = (__bridge NSDictionary*)info;
                NSString* ident = dict[(__bridge NSString*)kSecCodeInfoIdentifier];
                if (ident && valStatus == errSecSuccess) {
                    out_status->code_signed = true;
                    snprintf(out_status->code_identifier, sizeof(out_status->code_identifier), "%s", ident.UTF8String);
                }
                NSNumber* flagsNum = dict[(__bridge NSString*)kSecCodeInfoFlags];
                if (flagsNum) {
                    const uint32_t flags = flagsNum.unsignedIntValue;
                    out_status->hardened_runtime = (flags & kSecCodeSignatureRuntime) != 0;
                }
                NSData* cdhash = dict[(__bridge NSString*)kSecCodeInfoUnique];
                if (cdhash) {
                    NSString* hex = hex_from_nsdata(cdhash);
                    snprintf(out_status->cdhash_sha256_hex, sizeof(out_status->cdhash_sha256_hex), "%s", hex.UTF8String);
                }
                CFRelease(info);
            }
            CFRelease(staticCode);
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
    if (!status || !nonce_hex || !nonce_hex[0] || !out_json || out_json_cap < 512) {
        set_err(err_buf, err_buf_cap, "invalid arguments to sign_challenge");
        return false;
    }

    @autoreleasepool {
        NSDictionary* keyAttrs = @{
            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
            (__bridge id)kSecAttrKeySizeInBits: @256,
            (__bridge id)kSecAttrIsPermanent: @NO,
        };
        CFErrorRef cfErr = nullptr;
        SecKeyRef privKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)keyAttrs, &cfErr);
        if (!privKey) {
            NSError* e = (__bridge_transfer NSError*)cfErr;
            set_err(err_buf, err_buf_cap, e ? e.localizedDescription.UTF8String : "SecKeyCreateRandomKey failed");
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
            NSError* e = (__bridge_transfer NSError*)cfErr;
            set_err(err_buf, err_buf_cap, e ? e.localizedDescription.UTF8String : "SecKeyCopyExternalRepresentation failed");
            return false;
        }

        NSISO8601DateFormatter* isoFmt = [[NSISO8601DateFormatter alloc] init];
        NSString* ts = [isoFmt stringFromDate:[NSDate date]];

        NSDictionary* claims = @{
            @"nonce": [NSString stringWithUTF8String:nonce_hex],
            @"timestamp_utc": ts ?: @"",
            @"macos_version": [NSString stringWithUTF8String:status->macos_version],
            @"macos_build": [NSString stringWithUTF8String:status->macos_build],
            @"hardware_model": [NSString stringWithUTF8String:status->hardware_model],
            @"sip_enabled": @(status->sip_enabled),
            @"ssv_sealed": @(status->ssv_sealed),
            @"dc_app_attest_supported": @(status->dc_app_attest_supported),
            @"code_signed": @(status->code_signed),
            @"hardened_runtime": @(status->hardened_runtime),
            @"sandbox_active": @(status->sandbox_active),
            @"code_identifier": [NSString stringWithUTF8String:status->code_identifier],
            @"cdhash": [NSString stringWithUTF8String:status->cdhash_sha256_hex],
            @"binary_sha256": [NSString stringWithUTF8String:status->binary_sha256_hex],
        };

        NSError* jsonErr = nil;
        NSData* canonicalData = [NSJSONSerialization dataWithJSONObject:claims
                                                                options:NSJSONWritingSortedKeys
                                                                  error:&jsonErr];
        if (!canonicalData) {
            CFRelease(privKey);
            set_err(err_buf, err_buf_cap, jsonErr ? jsonErr.localizedDescription.UTF8String : "JSON encode failed");
            return false;
        }
        NSString* canonicalStr = [[NSString alloc] initWithData:canonicalData encoding:NSUTF8StringEncoding];

        cfErr = nullptr;
        NSData* sig = (__bridge_transfer NSData*)SecKeyCreateSignature(
            privKey,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
            (__bridge CFDataRef)canonicalData,
            &cfErr);
        CFRelease(privKey);
        if (!sig) {
            NSError* e = (__bridge_transfer NSError*)cfErr;
            set_err(err_buf, err_buf_cap, e ? e.localizedDescription.UTF8String : "SecKeyCreateSignature failed");
            return false;
        }

        NSDictionary* bundle = @{
            @"schema": @"directmetal.attestation.v1",
            @"algorithm": @"ECDSA-P256-SHA256-X962",
            @"public_key_x963_b64": [pubRaw base64EncodedStringWithOptions:0],
            @"key_id_sha256": sha256_hex_nsdata(pubRaw),
            @"signature_b64": [sig base64EncodedStringWithOptions:0],
            @"payload_canonical": canonicalStr,
            @"claims": claims,
        };
        NSData* bundleData = [NSJSONSerialization dataWithJSONObject:bundle
                                                             options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                               error:&jsonErr];
        if (!bundleData || bundleData.length + 1 >= out_json_cap) {
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
        NSString* schema = bundle[@"schema"];
        NSString* pubB64 = bundle[@"public_key_x963_b64"];
        NSString* keyId = bundle[@"key_id_sha256"];
        NSString* sigB64 = bundle[@"signature_b64"];
        NSString* canonical = bundle[@"payload_canonical"];
        NSDictionary* claims = bundle[@"claims"];
        if (![schema isEqualToString:@"directmetal.attestation.v1"] ||
            ![pubB64 isKindOfClass:[NSString class]] ||
            ![sigB64 isKindOfClass:[NSString class]] ||
            ![canonical isKindOfClass:[NSString class]] ||
            ![claims isKindOfClass:[NSDictionary class]]) {
            set_err(err_buf, err_buf_cap, "missing required bundle fields");
            return false;
        }

        NSData* pubData = [[NSData alloc] initWithBase64EncodedString:pubB64 options:0];
        NSData* sigData = [[NSData alloc] initWithBase64EncodedString:sigB64 options:0];
        NSData* payloadData = [canonical dataUsingEncoding:NSUTF8StringEncoding];
        if (!pubData || !sigData || !payloadData) {
            set_err(err_buf, err_buf_cap, "base64/UTF-8 decode failed");
            return false;
        }
        if (keyId && ![sha256_hex_nsdata(pubData) isEqualToString:keyId]) {
            set_err(err_buf, err_buf_cap, "key_id_sha256 mismatch");
            return false;
        }

        /* Ensure claims dictionary inside bundle matches signed payload_canonical exactly */
        NSDictionary* signedClaims = [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:&jsonErr];
        if (![signedClaims isKindOfClass:[NSDictionary class]] || ![signedClaims isEqualToDictionary:claims]) {
            set_err(err_buf, err_buf_cap, "claims dictionary differs from signed payload_canonical");
            return false;
        }
        if (expected_nonce_hex && expected_nonce_hex[0]) {
            NSString* gotNonce = signedClaims[@"nonce"];
            if (![gotNonce isEqualToString:[NSString stringWithUTF8String:expected_nonce_hex]]) {
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
            set_err(err_buf, err_buf_cap, "SecKeyCreateWithData failed");
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
            set_err(err_buf, err_buf_cap, "ECDSA signature verification failed");
            return false;
        }
        return true;
    }
}
