#undef NDEBUG
#include "dm_prefix.h"

#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void write_file_str(const char *path, const char *content) {
    FILE *f = fopen(path, "w");
    assert(f != NULL);
    fputs(content, f);
    fclose(f);
}

static void read_file_str(const char *path, char *buf, size_t cap) {
    FILE *f = fopen(path, "r");
    assert(f != NULL);
    size_t n = fread(buf, 1, cap - 1, f);
    buf[n] = '\0';
    fclose(f);
}

static const char *skip_json_ws(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
        ++p;
    }
    return p;
}

static const char *parse_rfc8259_string(const char *p) {
    if (*p != '"') return NULL;
    ++p;
    while (*p != '\0') {
        unsigned char c = (unsigned char)*p;
        if (c < 0x20) return NULL;  // Unescaped control char forbidden by RFC 8259
        if (c == '"') return p + 1;
        if (c == '\\') {
            ++p;
            switch (*p) {
                case '"':
                case '\\':
                case '/':
                case 'b':
                case 'f':
                case 'n':
                case 'r':
                case 't':
                    ++p;
                    break;
                case 'u':
                    for (int i = 1; i <= 4; ++i) {
                        if (!isxdigit((unsigned char)p[i])) return NULL;
                    }
                    p += 5;
                    break;
                default:
                    return NULL;
            }
        } else {
            ++p;
        }
    }
    return NULL;
}

static const char *parse_rfc8259_number(const char *p) {
    if (*p == '-') ++p;
    if (*p == '0') {
        ++p;
    } else if (*p >= '1' && *p <= '9') {
        while (isdigit((unsigned char)*p)) ++p;
    } else {
        return NULL;
    }
    if (*p == '.') {
        ++p;
        if (!isdigit((unsigned char)*p)) return NULL;
        while (isdigit((unsigned char)*p)) ++p;
    }
    if (*p == 'e' || *p == 'E') {
        ++p;
        if (*p == '+' || *p == '-') ++p;
        if (!isdigit((unsigned char)*p)) return NULL;
        while (isdigit((unsigned char)*p)) ++p;
    }
    return p;
}

static bool is_valid_rfc8259_json_object(const char *src) {
    if (!src) return false;
    const char *p = skip_json_ws(src);
    if (*p != '{') return false;
    p = skip_json_ws(p + 1);
    if (*p == '}') {
        p = skip_json_ws(p + 1);
        return *p == '\0';
    }
    for (;;) {
        p = parse_rfc8259_string(p);
        if (!p) return false;
        p = skip_json_ws(p);
        if (*p != ':') return false;
        p = skip_json_ws(p + 1);
        if (*p == '"') {
            p = parse_rfc8259_string(p);
        } else {
            p = parse_rfc8259_number(p);
        }
        if (!p) return false;
        p = skip_json_ws(p);
        if (*p == ',') {
            p = skip_json_ws(p + 1);
            continue;
        }
        if (*p == '}') {
            p = skip_json_ws(p + 1);
            return *p == '\0';
        }
        return false;
    }
}

static void test_invalid_args_and_delete_guards(const char *root,
                                                const char *base,
                                                const char *prefixes_dir,
                                                const char *existing_dest) {
    char tmp_dest[512];
    snprintf(tmp_dest, sizeof(tmp_dest), "%s/never_created", prefixes_dir);

    // dm_prefix_create invalid/null guards
    dm_prefix_result_t r = dm_prefix_create(NULL, tmp_dest, "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == EINVAL);
    r = dm_prefix_create("", tmp_dest, "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == EINVAL);
    r = dm_prefix_create(base, NULL, "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == EINVAL);
    r = dm_prefix_create(base, "", "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == EINVAL);

    char missing_base[512];
    snprintf(missing_base, sizeof(missing_base), "%s/nonexistent_base", root);
    r = dm_prefix_create(missing_base, tmp_dest, "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == ENOENT);

    r = dm_prefix_create(base, existing_dest, "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == EEXIST);

    char overlong[PATH_MAX + 16];
    memset(overlong, 'a', sizeof(overlong) - 1);
    overlong[0] = '/';
    overlong[sizeof(overlong) - 1] = '\0';
    r = dm_prefix_create(base, overlong, "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == ENAMETOOLONG);

    // dm_prefix_delete dangerous/invalid name guards
    r = dm_prefix_delete(NULL);
    assert(!r.ok && r.err_no == EINVAL);
    r = dm_prefix_delete("");
    assert(!r.ok && r.err_no == EINVAL);
    r = dm_prefix_delete("/");
    assert(!r.ok && r.err_no == EINVAL);

    // Isolated dot-path traversal rejection check (rmdir on trailing "/." fails with EINVAL)
    char dot_box[512], dot_target[512];
    snprintf(dot_box, sizeof(dot_box), "%s/dot_guard_box", root);
    snprintf(dot_target, sizeof(dot_target), "%s/.", dot_box);
    assert(mkdir(dot_box, 0755) == 0);
    r = dm_prefix_delete(dot_target);
    assert(!r.ok && r.err_no == EINVAL);
    assert(rmdir(dot_box) == 0);

    // dm_prefix_reset invalid destination guards
    r = dm_prefix_reset(base, NULL, "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == EINVAL);
    r = dm_prefix_reset(base, "", "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == EINVAL);
    r = dm_prefix_reset(base, "/", "a.exe", "D3D12", "k");
    assert(!r.ok && r.err_no == EINVAL);

    // dm_prefix_list null output / invalid argument guards
    char names[8][256];
    size_t count = 99;
    assert(dm_prefix_list(NULL, names, 8, &count) == EINVAL && count == 0);
    count = 99;
    assert(dm_prefix_list("", names, 8, &count) == EINVAL && count == 0);
    count = 99;
    assert(dm_prefix_list(prefixes_dir, NULL, 8, &count) == EINVAL && count == 0);
    count = 99;
    assert(dm_prefix_list(prefixes_dir, NULL, 0, &count) == 0 && count == 0);
    assert(dm_prefix_list(prefixes_dir, names, 8, NULL) == 0);  // null out_count safe
    count = 99;
    assert(dm_prefix_list(missing_base, names, 8, &count) == ENOENT && count == 0);

    printf("[dm_prefix_test] null/invalid args & delete safety guards OK\n");
}

static void test_rfc8259_json_escaping(const char *base, const char *prefixes_dir) {
    // Self-check RFC 8259 validator rejects unescaped backslashes, quotes, and control chars
    assert(!is_valid_rfc8259_json_object("{\"game_exe\": \"C:\\Games\\Hades\\Hades.exe\"}"));
    assert(!is_valid_rfc8259_json_object("{\"dx_api\": \"D3D12 \"quoted\"\"}"));
    assert(!is_valid_rfc8259_json_object("{\"key\": \"raw\nnewline\"}"));

    char hades_dest[512], meta_file[512];
    snprintf(hades_dest, sizeof(hades_dest), "%s/game_hades", prefixes_dir);
    dm_prefix_result_t res = dm_prefix_create(
        base,
        hades_dest,
        "C:\\Games\\Hades\\Hades.exe",
        "D3D12 \"Ultimate\"",
        "apple7_\"quoted\"\\key\t\n\x01");
    assert(res.ok);

    snprintf(meta_file, sizeof(meta_file), "%s/directmetal_prefix.json", hades_dest);
    char meta_buf[2048];
    read_file_str(meta_file, meta_buf, sizeof(meta_buf));

    assert(is_valid_rfc8259_json_object(meta_buf));
    assert(strstr(meta_buf, "\"game_exe\": \"C:\\\\Games\\\\Hades\\\\Hades.exe\"") != NULL);
    assert(strstr(meta_buf, "\"dx_api\": \"D3D12 \\\"Ultimate\\\"\"") != NULL);
    assert(strstr(meta_buf, "\"shader_cache_key\": \"apple7_\\\"quoted\\\"\\\\key\\t\\n\\u0001\"") != NULL);

    // Null optional metadata strings must serialize cleanly without crashing
    char null_meta_dest[512], null_meta_file[512];
    snprintf(null_meta_dest, sizeof(null_meta_dest), "%s/game_null_meta", prefixes_dir);
    res = dm_prefix_create(base, null_meta_dest, NULL, NULL, NULL);
    assert(res.ok);
    snprintf(null_meta_file, sizeof(null_meta_file), "%s/directmetal_prefix.json", null_meta_dest);
    read_file_str(null_meta_file, meta_buf, sizeof(meta_buf));
    assert(is_valid_rfc8259_json_object(meta_buf));
    assert(strstr(meta_buf, "\"dx_api\": \"auto\"") != NULL);

    assert(dm_prefix_delete(hades_dest).ok);
    assert(dm_prefix_delete(null_meta_dest).ok);
    printf("[dm_prefix_test] RFC 8259 JSON escaping OK\n");
}

int main(void) {
    char tmpl[] = "/tmp/dm_prefix_test_XXXXXX";
    char *root = mkdtemp(tmpl);
    assert(root != NULL);

    char base[512], nested[512], base_file[512];
    snprintf(base, sizeof(base), "%s/base-prefix", root);
    snprintf(nested, sizeof(nested), "%s/base-prefix/drive_c/windows/system32", root);
    assert(mkdir(base, 0755) == 0);
    char cdir[512], wdir[512];
    snprintf(cdir, sizeof(cdir), "%s/drive_c", base);
    snprintf(wdir, sizeof(wdir), "%s/drive_c/windows", base);
    assert(mkdir(cdir, 0755) == 0);
    assert(mkdir(wdir, 0755) == 0);
    assert(mkdir(nested, 0755) == 0);

    snprintf(base_file, sizeof(base_file), "%s/system.reg", base);
    write_file_str(base_file, "BASE_REG_V1\n");
    for (int i = 0; i < 32; ++i) {
        char fpath[512];
        snprintf(fpath, sizeof(fpath), "%s/fake_dll_%02d.dll", nested, i);
        write_file_str(fpath, "MZ_DUMMY_PAYLOAD");
    }

    char prefixes_dir[512], dest[512];
    snprintf(prefixes_dir, sizeof(prefixes_dir), "%s/prefixes", root);
    snprintf(dest, sizeof(dest), "%s/game_alpha", prefixes_dir);

    dm_prefix_result_t res = dm_prefix_create(
        base, dest, "game_alpha.exe", "D3D12", "apple7_25B78");
    assert(res.ok);
    printf("[dm_prefix_test] APFS CoW clonefile time: %.3f ms\n", res.elapsed_ms);
    assert(res.elapsed_ms < 50.0);

    // Verify CoW isolation: mutate cloned file and verify base stays unchanged
    char cloned_file[512], meta_file[512];
    snprintf(cloned_file, sizeof(cloned_file), "%s/system.reg", dest);
    write_file_str(cloned_file, "CLONE_MUTATED_V2\n");

    char base_buf[128], clone_buf[128];
    read_file_str(base_file, base_buf, sizeof(base_buf));
    read_file_str(cloned_file, clone_buf, sizeof(clone_buf));
    assert(strcmp(base_buf, "BASE_REG_V1\n") == 0);
    assert(strcmp(clone_buf, "CLONE_MUTATED_V2\n") == 0);

    snprintf(meta_file, sizeof(meta_file), "%s/directmetal_prefix.json", dest);
    char meta_buf[1024];
    read_file_str(meta_file, meta_buf, sizeof(meta_buf));
    assert(is_valid_rfc8259_json_object(meta_buf));
    assert(strstr(meta_buf, "apple7_25B78") != NULL);

    char names[8][256];
    size_t count = 0;
    assert(dm_prefix_list(prefixes_dir, names, 8, &count) == 0);
    assert(count == 1 && strcmp(names[0], "game_alpha") == 0);

    test_invalid_args_and_delete_guards(root, base, prefixes_dir, dest);
    test_rfc8259_json_escaping(base, prefixes_dir);

    dm_prefix_result_t reset_res = dm_prefix_reset(
        base, dest, "game_alpha.exe", "D3D12", "apple7_25B78");
    assert(reset_res.ok);
    read_file_str(cloned_file, clone_buf, sizeof(clone_buf));
    assert(strcmp(clone_buf, "BASE_REG_V1\n") == 0);

    dm_prefix_result_t del_res = dm_prefix_delete(root);
    assert(del_res.ok);
    printf("[dm_prefix_test] CoW isolation, list, reset, delete OK\n");
    return 0;
}
