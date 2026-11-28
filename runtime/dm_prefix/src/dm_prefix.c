#include "dm_prefix.h"

#include <dirent.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static bool mkdir_p(const char *path) {
    if (!path) {
        errno = EINVAL;
        return false;
    }
    char tmp[PATH_MAX];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) {
        errno = (len == 0) ? EINVAL : ENAMETOOLONG;
        return false;
    }
    memcpy(tmp, path, len + 1);
    while (len > 1 && tmp[len - 1] == '/') {
        tmp[--len] = '\0';
    }
    for (char *p = tmp + 1; *p; ++p) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return false;
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return false;
    return true;
}

static bool remove_recursive(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        return errno == ENOENT;
    }
    if (!S_ISDIR(st.st_mode)) {
        return unlink(path) == 0;
    }
    DIR *dir = opendir(path);
    if (!dir) return false;
    struct dirent *ent;
    bool ok = true;
    int saved_err = 0;
    while ((ent = readdir(dir)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        char child[PATH_MAX];
        int n = snprintf(child, sizeof(child), "%s/%s", path, ent->d_name);
        if (n < 0 || (size_t)n >= sizeof(child)) {
            saved_err = ENAMETOOLONG;
            ok = false;
            break;
        }
        if (!remove_recursive(child)) {
            saved_err = errno;
            ok = false;
            break;
        }
    }
    closedir(dir);
    if (!ok) {
        errno = saved_err ? saved_err : EIO;
        return false;
    }
    if (rmdir(path) != 0) return false;
    return true;
}

static void fputs_json_escaped(FILE *f, const char *s) {
    if (!s) return;
    for (const unsigned char *p = (const unsigned char *)s; *p != '\0'; ++p) {
        switch (*p) {
            case '"':  fputs("\\\"", f); break;
            case '\\': fputs("\\\\", f); break;
            case '\b': fputs("\\b", f); break;
            case '\f': fputs("\\f", f); break;
            case '\n': fputs("\\n", f); break;
            case '\r': fputs("\\r", f); break;
            case '\t': fputs("\\t", f); break;
            default:
                if (*p < 0x20) {
                    fprintf(f, "\\u%04x", (unsigned int)*p);
                } else {
                    fputc((int)*p, f);
                }
                break;
        }
    }
}

static void write_metadata_json(const char *dest_prefix,
                                const char *base_prefix,
                                const char *game_exe,
                                const char *dx_api,
                                const char *shader_key,
                                double clone_ms) {
    char meta_path[PATH_MAX];
    int mlen = snprintf(meta_path, sizeof(meta_path), "%s/directmetal_prefix.json", dest_prefix);
    if (mlen < 0 || (size_t)mlen >= sizeof(meta_path)) return;
    FILE *f = fopen(meta_path, "w");
    if (!f) return;

    time_t t = time(NULL);
    struct tm tm_utc;
    gmtime_r(&t, &tm_utc);
    char iso[64];
    strftime(iso, sizeof(iso), "%Y-%m-%dT%H:%M:%SZ", &tm_utc);

    fprintf(f, "{\n  \"created_utc\": \"%s\",\n  \"base_prefix\": \"", iso);
    fputs_json_escaped(f, base_prefix ? base_prefix : "");
    fputs("\",\n  \"game_exe\": \"", f);
    fputs_json_escaped(f, game_exe ? game_exe : "");
    fputs("\",\n  \"dx_api\": \"", f);
    fputs_json_escaped(f, (dx_api && dx_api[0]) ? dx_api : "auto");
    fputs("\",\n  \"shader_cache_key\": \"", f);
    fputs_json_escaped(f, shader_key ? shader_key : "");
    fprintf(f, "\",\n  \"cow_clone_ms\": %.3f\n}\n", clone_ms);
    fclose(f);
}

dm_prefix_result_t dm_prefix_create(const char *base_prefix,
                                    const char *dest_prefix,
                                    const char *game_exe,
                                    const char *dx_api,
                                    const char *shader_key) {
    dm_prefix_result_t res;
    memset(&res, 0, sizeof(res));

    if (!base_prefix || !dest_prefix || !base_prefix[0] || !dest_prefix[0]) {
        res.err_no = EINVAL;
        snprintf(res.error_msg, sizeof(res.error_msg), "Invalid prefix arguments");
        return res;
    }

    struct stat st;
    if (stat(base_prefix, &st) != 0 || !S_ISDIR(st.st_mode)) {
        res.err_no = errno ? errno : ENOENT;
        snprintf(res.error_msg, sizeof(res.error_msg), "Base prefix not found: %s", base_prefix);
        return res;
    }
    if (lstat(dest_prefix, &st) == 0) {
        res.err_no = EEXIST;
        snprintf(res.error_msg, sizeof(res.error_msg), "Destination prefix already exists: %s", dest_prefix);
        return res;
    }

    char parent_buf[PATH_MAX];
    int plen = snprintf(parent_buf, sizeof(parent_buf), "%s", dest_prefix);
    if (plen < 0 || (size_t)plen >= sizeof(parent_buf)) {
        res.err_no = ENAMETOOLONG;
        snprintf(res.error_msg, sizeof(res.error_msg), "Destination prefix path too long");
        return res;
    }
    char *parent = dirname(parent_buf);
    if (!mkdir_p(parent)) {
        res.err_no = errno;
        snprintf(res.error_msg, sizeof(res.error_msg), "Failed to create parent directory");
        return res;
    }

    const double t0 = now_ms();
    if (clonefile(base_prefix, dest_prefix, CLONE_NOFOLLOW) != 0) {
        res.err_no = errno;
        snprintf(res.error_msg, sizeof(res.error_msg), "clonefile failed: %s", strerror(errno));
        return res;
    }
    res.elapsed_ms = now_ms() - t0;
    write_metadata_json(dest_prefix, base_prefix, game_exe, dx_api, shader_key, res.elapsed_ms);
    res.ok = true;
    return res;
}

dm_prefix_result_t dm_prefix_delete(const char *prefix_path) {
    dm_prefix_result_t res;
    memset(&res, 0, sizeof(res));
    if (!prefix_path || !prefix_path[0] || strcmp(prefix_path, "/") == 0) {
        res.err_no = EINVAL;
        snprintf(res.error_msg, sizeof(res.error_msg), "Invalid prefix path");
        return res;
    }
    const double t0 = now_ms();
    if (!remove_recursive(prefix_path)) {
        res.err_no = errno;
        snprintf(res.error_msg, sizeof(res.error_msg), "Failed to remove prefix: %s", strerror(errno));
        return res;
    }
    res.elapsed_ms = now_ms() - t0;
    res.ok = true;
    return res;
}

dm_prefix_result_t dm_prefix_reset(const char *base_prefix,
                                   const char *dest_prefix,
                                   const char *game_exe,
                                   const char *dx_api,
                                   const char *shader_key) {
    dm_prefix_result_t del = dm_prefix_delete(dest_prefix);
    if (!del.ok) return del;
    return dm_prefix_create(base_prefix, dest_prefix, game_exe, dx_api, shader_key);
}

int dm_prefix_list(const char *prefix_root,
                   char names_out[][256],
                   size_t max_names,
                   size_t *out_count) {
    if (out_count) *out_count = 0;
    if (!prefix_root || !prefix_root[0] || (max_names > 0 && !names_out)) return EINVAL;
    DIR *dir = opendir(prefix_root);
    if (!dir) return errno;

    size_t n = 0;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL && n < max_names) {
        if (ent->d_name[0] == '.') continue;
        char full[PATH_MAX];
        int flen = snprintf(full, sizeof(full), "%s/%s", prefix_root, ent->d_name);
        if (flen < 0 || (size_t)flen >= sizeof(full)) continue;
        struct stat st;
        if (stat(full, &st) == 0 && S_ISDIR(st.st_mode)) {
            snprintf(names_out[n], 256, "%s", ent->d_name);
            ++n;
        }
    }
    closedir(dir);
    if (out_count) *out_count = n;
    return 0;
}
