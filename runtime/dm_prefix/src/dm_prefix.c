#include "dm_prefix.h"

#include <dirent.h>
#include <errno.h>
#include <libgen.h>
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
    char tmp[1024];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp)) return false;
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
    while ((ent = readdir(dir)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        char child[2048];
        snprintf(child, sizeof(child), "%s/%s", path, ent->d_name);
        if (!remove_recursive(child)) {
            ok = false;
            break;
        }
    }
    closedir(dir);
    if (ok && rmdir(path) != 0) ok = false;
    return ok;
}

static void write_metadata_json(const char *dest_prefix,
                                const char *base_prefix,
                                const char *game_exe,
                                const char *dx_api,
                                const char *shader_key,
                                double clone_ms) {
    char meta_path[1024];
    snprintf(meta_path, sizeof(meta_path), "%s/directmetal_prefix.json", dest_prefix);
    FILE *f = fopen(meta_path, "w");
    if (!f) return;

    time_t t = time(NULL);
    struct tm tm_utc;
    gmtime_r(&t, &tm_utc);
    char iso[64];
    strftime(iso, sizeof(iso), "%Y-%m-%dT%H:%M:%SZ", &tm_utc);

    fprintf(f,
            "{\n"
            "  \"created_utc\": \"%s\",\n"
            "  \"base_prefix\": \"%s\",\n"
            "  \"game_exe\": \"%s\",\n"
            "  \"dx_api\": \"%s\",\n"
            "  \"shader_cache_key\": \"%s\",\n"
            "  \"cow_clone_ms\": %.3f\n"
            "}\n",
            iso,
            base_prefix ? base_prefix : "",
            game_exe ? game_exe : "",
            dx_api ? dx_api : "auto",
            shader_key ? shader_key : "",
            clone_ms);
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

    char parent_buf[1024];
    snprintf(parent_buf, sizeof(parent_buf), "%s", dest_prefix);
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
    if (!prefix_path || !prefix_path[0]) {
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
    if (!prefix_root) return EINVAL;
    DIR *dir = opendir(prefix_root);
    if (!dir) return errno;

    size_t n = 0;
    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL && n < max_names) {
        if (ent->d_name[0] == '.') continue;
        char full[1024];
        snprintf(full, sizeof(full), "%s/%s", prefix_root, ent->d_name);
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
