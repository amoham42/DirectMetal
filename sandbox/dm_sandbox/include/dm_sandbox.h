#ifndef DM_SANDBOX_H
#define DM_SANDBOX_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dm_sandbox_config {
    const char* template_path;     /* Path to directmetal_game.sb.tmpl */
    const char* prefixes_root;     /* Parent directory containing all Wine prefixes */
    const char* target_prefix;     /* Allowed Wine prefix directory */
    const char* game_dir;          /* Read-only game directory */
    const char* shader_cache_dir;  /* Read-write shader cache directory */
    const char* output_dir;        /* Read-write output/capture directory (optional; defaults to target_prefix) */
    const char* user_home;         /* HOME directory (optional; defaults to getenv("HOME")) */
    bool allow_network;            /* If false, blocks remote IPv4/IPv6 network traffic */
} dm_sandbox_config_t;

/* Canonicalizes paths and renders an SBPL v1 Seatbelt profile into out_buf. */
bool dm_sandbox_render_profile(const dm_sandbox_config_t* cfg,
                               char* out_buf,
                               size_t out_buf_cap,
                               char* err_buf,
                               size_t err_buf_cap);

/* Renders the SBPL v1 profile and writes it atomically to profile_path. */
bool dm_sandbox_write_profile(const dm_sandbox_config_t* cfg,
                              const char* profile_path,
                              char* err_buf,
                              size_t err_buf_cap);

/* Executes argv[0..] inside /usr/bin/sandbox-exec -f profile_path and returns waitpid exit code (-1 on fork/exec error). */
int dm_sandbox_exec_profiled(const char* profile_path,
                             char* const argv[]);

#ifdef __cplusplus
}
#endif

#endif /* DM_SANDBOX_H */
