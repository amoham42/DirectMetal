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
    if (!in_path || !in_path[0]) return false;
    if (realpath(in_path, out_path) != NULL) {
        return true;
    }
    char work[PATH_MAX];
    char tail[PATH_MAX];
    tail[0] = '\0';
    snprintf(work, sizeof(work), "%s", in_path);

    size_t len = strlen(work);
    while (len > 1 && work[len - 1] == '/') {
        work[--len] = '\0';
    }

    while (len > 1) {
        char resolved[PATH_MAX];
        if (realpath(work, resolved) != NULL) {
            snprintf(out_path, PATH_MAX, "%s%s", resolved, tail);
            return true;
        }
        char* slash = strrchr(work, '/');
        if (!slash) break;
        char new_tail[PATH_MAX];
        snprintf(new_tail, sizeof(new_tail), "%s%s", slash, tail);
        snprintf(tail, sizeof(tail), "%s", new_tail);
        if (slash == work) {
            work[1] = '\0';
            len = 1;
        } else {
            *slash = '\0';
            len = strlen(work);
        }
    }
    snprintf(out_path, PATH_MAX, "%s", in_path);
    return true;
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
        snprintf(err_buf, err_buf_cap, "failed to open template: %s (%s)",
                 cfg->template_path, strerror(errno));
        return false;
    }
    char tmpl[16384];
    const size_t nread = fread(tmpl, 1, sizeof(tmpl) - 1, fp);
    fclose(fp);
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
    fclose(fp);
    if (written != len) {
        set_err(err_buf, err_buf_cap, "short write on sandbox profile");
        return false;
    }
    return true;
}

int dm_sandbox_exec_profiled(const char* profile_path,
                             char* const argv[]) {
    if (!profile_path || !argv || !argv[0]) return -1;

    size_t argc = 0;
    while (argv[argc] != NULL) ++argc;
    char** child_argv = calloc(argc + 4, sizeof(char*));
    if (!child_argv) return -1;

    child_argv[0] = "/usr/bin/sandbox-exec";
    child_argv[1] = "-f";
    child_argv[2] = (char*)profile_path;
    for (size_t i = 0; i <= argc; ++i) {
        child_argv[3 + i] = argv[i];
    }

    pid_t pid = fork();
    if (pid < 0) {
        free(child_argv);
        return -1;
    }
    if (pid == 0) {
        execv("/usr/bin/sandbox-exec", child_argv);
        _exit(127);
    }
    free(child_argv);

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
