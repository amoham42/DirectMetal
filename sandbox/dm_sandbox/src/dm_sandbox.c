#include "dm_sandbox.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void set_err(char* err_buf, size_t cap, const char* msg) {
    if (err_buf && cap > 0) {
        snprintf(err_buf, cap, "%s", msg ? msg : "unknown error");
    }
}

/* Resolve symlinks (e.g. /var -> /private/var, /tmp -> /private/tmp) even if leaf dirs don't exist yet. */
static bool canonicalize_path(const char* in_path, char out_path[PATH_MAX]) {
    if (!in_path || !in_path[0] || !out_path) return false;
    if (realpath(in_path, out_path) != NULL) {
        return true;
    }
    char work[PATH_MAX];
    char tail[PATH_MAX];
    tail[0] = '\0';
    int wlen = snprintf(work, sizeof(work), "%s", in_path);
    if (wlen < 0 || (size_t)wlen >= sizeof(work)) return false;

    size_t len = (size_t)wlen;
    while (len > 1 && work[len - 1] == '/') {
        work[--len] = '\0';
    }

    while (len > 1) {
        char resolved[PATH_MAX];
        if (realpath(work, resolved) != NULL) {
            int rlen = snprintf(out_path, PATH_MAX, "%s%s", resolved, tail);
            return (rlen >= 0 && (size_t)rlen < PATH_MAX);
        }
        char* slash = strrchr(work, '/');
        if (!slash) break;
        char new_tail[PATH_MAX];
        int tlen = snprintf(new_tail, sizeof(new_tail), "%s%s", slash, tail);
        if (tlen < 0 || (size_t)tlen >= sizeof(new_tail)) return false;
        memcpy(tail, new_tail, (size_t)tlen + 1);
        if (slash == work) {
            work[1] = '\0';
            len = 1;
        } else {
            *slash = '\0';
            len = (size_t)(slash - work);
        }
    }
    int flen = snprintf(out_path, PATH_MAX, "%s", in_path);
    return (flen >= 0 && (size_t)flen < PATH_MAX);
}

static bool escape_sbpl_str(const char* src, char* dst, size_t dst_cap) {
    size_t j = 0;
    for (size_t i = 0; src[i] != '\0'; ++i) {
        const char c = src[i];
        if (c == '\n' || c == '\r') return false;
        if (c == '\\' || c == '"') {
            if (j + 2 >= dst_cap) return false;
            dst[j++] = '\\';
            dst[j++] = c;
        } else {
            if (j + 1 >= dst_cap) return false;
            dst[j++] = c;
        }
    }
    if (j >= dst_cap) return false;
    dst[j] = '\0';
    return true;
}

static bool append_str(char* dst, size_t cap, size_t* pos, const char* s) {
    const size_t slen = strlen(s);
    if (*pos + slen >= cap) return false;
    memcpy(dst + *pos, s, slen);
    *pos += slen;
    dst[*pos] = '\0';
    return true;
}

bool dm_sandbox_render_profile(const dm_sandbox_config_t* cfg,
                               char* out_buf,
                               size_t out_buf_cap,
                               char* err_buf,
                               size_t err_buf_cap) {
    if (!cfg || !out_buf || out_buf_cap < 256) {
        set_err(err_buf, err_buf_cap, "invalid arguments");
        return false;
    }
    if (!cfg->template_path || !cfg->prefixes_root || !cfg->target_prefix ||
        !cfg->game_dir || !cfg->shader_cache_dir) {
        set_err(err_buf, err_buf_cap, "missing required sandbox config path");
        return false;
    }

    const char* raw_home = cfg->user_home ? cfg->user_home : getenv("HOME");
    if (!raw_home || !raw_home[0]) {
        set_err(err_buf, err_buf_cap, "HOME not available");
        return false;
    }
    const char* raw_out = (cfg->output_dir && cfg->output_dir[0]) ? cfg->output_dir : cfg->target_prefix;

    char c_home[PATH_MAX], c_root[PATH_MAX], c_pfx[PATH_MAX], c_game[PATH_MAX], c_cache[PATH_MAX], c_out[PATH_MAX];
    if (!canonicalize_path(raw_home, c_home) ||
        !canonicalize_path(cfg->prefixes_root, c_root) ||
        !canonicalize_path(cfg->target_prefix, c_pfx) ||
        !canonicalize_path(cfg->game_dir, c_game) ||
        !canonicalize_path(cfg->shader_cache_dir, c_cache) ||
        !canonicalize_path(raw_out, c_out)) {
        set_err(err_buf, err_buf_cap, "failed to canonicalize path");
        return false;
    }

    char e_home[PATH_MAX * 2], e_root[PATH_MAX * 2], e_pfx[PATH_MAX * 2];
    char e_game[PATH_MAX * 2], e_cache[PATH_MAX * 2], e_out[PATH_MAX * 2];
    if (!escape_sbpl_str(c_home, e_home, sizeof(e_home)) ||
        !escape_sbpl_str(c_root, e_root, sizeof(e_root)) ||
        !escape_sbpl_str(c_pfx, e_pfx, sizeof(e_pfx)) ||
        !escape_sbpl_str(c_game, e_game, sizeof(e_game)) ||
        !escape_sbpl_str(c_cache, e_cache, sizeof(e_cache)) ||
        !escape_sbpl_str(c_out, e_out, sizeof(e_out))) {
        set_err(err_buf, err_buf_cap, "invalid characters in path");
        return false;
    }

    FILE* fp = fopen(cfg->template_path, "rb");
    if (!fp) {
        if (err_buf && err_buf_cap > 0) {
            snprintf(err_buf, err_buf_cap, "failed to open template: %s (%s)",
                     cfg->template_path, strerror(errno));
        }
        return false;
    }
    char tmpl[16384];
    size_t nread = 0;
    while (nread < sizeof(tmpl) - 1) {
        size_t chunk = fread(tmpl + nread, 1, (sizeof(tmpl) - 1) - nread, fp);
        if (chunk == 0) {
            if (ferror(fp)) {
                if (errno == EINTR) {
                    clearerr(fp);
                    continue;
                }
                fclose(fp);
                set_err(err_buf, err_buf_cap, "failed to read sandbox template");
                return false;
            }
            break;
        }
        nread += chunk;
    }
    const int extra = fgetc(fp);
    const bool hit_eof = (extra == EOF) && feof(fp) && !ferror(fp);
    fclose(fp);
    if (!hit_eof) {
        set_err(err_buf, err_buf_cap, "sandbox template exceeds maximum size or read failed");
        return false;
    }
    tmpl[nread] = '\0';

    const char* net_rules = cfg->allow_network
        ? "(allow network*)"
        : "(deny network-outbound (remote ip))\n(deny network-inbound (local ip))\n(allow network* (local unix-socket))\n(allow network* (remote unix-socket))";

    struct Sub { const char* key; const char* val; } subs[] = {
        {"${USER_HOME}", e_home},
        {"${PREFIXES_ROOT}", e_root},
        {"${TARGET_PREFIX}", e_pfx},
        {"${GAME_DIR}", e_game},
        {"${SHADER_CACHE_DIR}", e_cache},
        {"${OUTPUT_DIR}", e_out},
        {"${NETWORK_RULES}", net_rules},
    };

    size_t pos = 0;
    out_buf[0] = '\0';
    const char* cur = tmpl;
    while (*cur != '\0') {
        bool matched = false;
        for (size_t s = 0; s < sizeof(subs) / sizeof(subs[0]); ++s) {
            const size_t klen = strlen(subs[s].key);
            if (strncmp(cur, subs[s].key, klen) == 0) {
                if (!append_str(out_buf, out_buf_cap, &pos, subs[s].val)) {
                    set_err(err_buf, err_buf_cap, "profile output buffer too small");
                    return false;
                }
                cur += klen;
                matched = true;
                break;
            }
        }
        if (!matched) {
            if (pos + 1 >= out_buf_cap) {
                set_err(err_buf, err_buf_cap, "profile output buffer too small");
                return false;
            }
            out_buf[pos++] = *cur++;
            out_buf[pos] = '\0';
        }
    }
    return true;
}

bool dm_sandbox_write_profile(const dm_sandbox_config_t* cfg,
                              const char* profile_path,
                              char* err_buf,
                              size_t err_buf_cap) {
    if (!profile_path || !profile_path[0]) {
        set_err(err_buf, err_buf_cap, "invalid profile path");
        return false;
    }
    char buf[32768];
    if (!dm_sandbox_render_profile(cfg, buf, sizeof(buf), err_buf, err_buf_cap)) {
        return false;
    }
    FILE* fp = fopen(profile_path, "wb");
    if (!fp) {
        if (err_buf && err_buf_cap > 0) {
            snprintf(err_buf, err_buf_cap, "failed to write %s: %s", profile_path, strerror(errno));
        }
        return false;
    }
    const size_t len = strlen(buf);
    const size_t written = fwrite(buf, 1, len, fp);
    const int close_rc = fclose(fp);
    if (written != len || close_rc != 0) {
        set_err(err_buf, err_buf_cap, "short write on sandbox profile");
        return false;
    }
    return true;
}

int dm_sandbox_exec_profiled(const char* profile_path,
                             char* const argv[]) {
    if (!profile_path || !profile_path[0] || !argv || !argv[0]) return -1;

    size_t argc = 0;
    while (argv[argc] != NULL) ++argc;
    char** child_argv = calloc(argc + 4, sizeof(char*));
    if (!child_argv) return -1;

    char sandbox_bin[] = "/usr/bin/sandbox-exec";
    char flag_f[] = "-f";
    char* profile_arg = strdup(profile_path);
    if (!profile_arg) {
        free(child_argv);
        return -1;
    }

    child_argv[0] = sandbox_bin;
    child_argv[1] = flag_f;
    child_argv[2] = profile_arg;
    for (size_t i = 0; i <= argc; ++i) {
        child_argv[3 + i] = argv[i];
    }

    pid_t pid = fork();
    if (pid < 0) {
        free(profile_arg);
        free(child_argv);
        return -1;
    }
    if (pid == 0) {
        execv(sandbox_bin, child_argv);
        _exit(127);
    }
    free(profile_arg);
    free(child_argv);

    int status = 0;
    pid_t wpid;
    do {
        wpid = waitpid(pid, &status, 0);
    } while (wpid < 0 && errno == EINTR);
    if (wpid < 0) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
