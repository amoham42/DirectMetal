#include "dm_sandbox.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int mkdir_p(const char* path) {
    char tmp[1024];
    snprintf(tmp, sizeof(tmp), "%s", path);
    for (char* p = tmp + 1; *p; ++p) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    return mkdir(tmp, 0755) == 0 || errno == EEXIST ? 0 : -1;
}

static int run_worker_checks(const char* target_write,
                             const char* cache_write,
                             const char* sibling_secret,
                             const char* home_ssh,
                             const char* forbidden_home_write) {
    int fails = 0;

    /* 1. Target prefix RW must succeed */
    int fd = open(target_write, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "FAIL: target prefix write denied (%s)\n", strerror(errno));
        ++fails;
    } else {
        const char* ok = "prefix-rw-ok\n";
        (void)write(fd, ok, strlen(ok));
        close(fd);
    }

    /* 2. Shader cache RW must succeed */
    fd = open(cache_write, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "FAIL: cache write denied (%s)\n", strerror(errno));
        ++fails;
    } else {
        const char* ok = "cache-rw-ok\n";
        (void)write(fd, ok, strlen(ok));
        close(fd);
    }

    /* 3. Sibling Wine prefix read MUST return EPERM */
    errno = 0;
    fd = open(sibling_secret, O_RDONLY);
    if (fd >= 0) {
        close(fd);
        fprintf(stderr, "FAIL: sibling prefix read WAS ALLOWED unexpectedly!\n");
        ++fails;
    } else if (errno != EPERM) {
        fprintf(stderr, "FAIL: sibling prefix returned errno=%d (%s) instead of EPERM\n", errno, strerror(errno));
        ++fails;
    } else {
        printf("  [PASS] Sibling prefix read blocked by Seatbelt (EPERM)\n");
    }

    /* 4. ~/.ssh access MUST return EPERM */
    errno = 0;
    fd = open(home_ssh, O_RDONLY);
    if (fd >= 0) {
        close(fd);
        fprintf(stderr, "FAIL: ~/.ssh read WAS ALLOWED unexpectedly!\n");
        ++fails;
    } else if (errno != EPERM) {
        fprintf(stderr, "FAIL: ~/.ssh probe returned errno=%d (%s) instead of EPERM\n", errno, strerror(errno));
        ++fails;
    } else {
        printf("  [PASS] Sensitive ~/.ssh probe blocked by Seatbelt (EPERM)\n");
    }

    /* 5. Unapproved write under HOME MUST return EPERM */
    errno = 0;
    fd = open(forbidden_home_write, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        close(fd);
        unlink(forbidden_home_write);
        fprintf(stderr, "FAIL: unapproved HOME write WAS ALLOWED unexpectedly!\n");
        ++fails;
    } else if (errno != EPERM) {
        fprintf(stderr, "FAIL: unapproved HOME write returned errno=%d (%s) instead of EPERM\n", errno, strerror(errno));
        ++fails;
    } else {
        printf("  [PASS] Unapproved HOME write blocked by Seatbelt (EPERM)\n");
    }

    return fails == 0 ? 0 : 1;
}

int main(int argc, char** argv) {
    if (argc >= 7 && strcmp(argv[1], "--worker") == 0) {
        return run_worker_checks(argv[2], argv[3], argv[4], argv[5], argv[6]);
    }

    const char* tmpl = (argc >= 2) ? argv[1] : "sandbox/profiles/directmetal_game.sb.tmpl";
    const char* home = getenv("HOME");
    if (!home) {
        fprintf(stderr, "HOME not set\n");
        return 1;
    }

    /* Use a temp sandbox test workspace inside HOME so HOME write-deny vs prefix allow is exercised strictly! */
    char test_root[512];
    snprintf(test_root, sizeof(test_root), "%s/.directmetal_sandbox_test_%d", home, (int)getpid());
    char pfx_root[512], pfx_alpha[512], pfx_beta[512], game_dir[512], cache_dir[512], profile_path[512];
    snprintf(pfx_root, sizeof(pfx_root), "%s/prefixes", test_root);
    snprintf(pfx_alpha, sizeof(pfx_alpha), "%s/alpha", pfx_root);
    snprintf(pfx_beta, sizeof(pfx_beta), "%s/beta", pfx_root);
    snprintf(game_dir, sizeof(game_dir), "%s/game", test_root);
    snprintf(cache_dir, sizeof(cache_dir), "%s/cache", test_root);
    snprintf(profile_path, sizeof(profile_path), "%s/test.sb", test_root);

    mkdir_p(pfx_alpha);
    mkdir_p(pfx_beta);
    mkdir_p(game_dir);
    mkdir_p(cache_dir);

    char sibling_secret[512], target_write[512], cache_write[512], home_ssh[512], forbidden_write[512];
    snprintf(sibling_secret, sizeof(sibling_secret), "%s/save_secret.txt", pfx_beta);
    snprintf(target_write, sizeof(target_write), "%s/alpha_save.txt", pfx_alpha);
    snprintf(cache_write, sizeof(cache_write), "%s/pipeline.bin", cache_dir);
    snprintf(home_ssh, sizeof(home_ssh), "%s/.ssh", home);
    snprintf(forbidden_write, sizeof(forbidden_write), "%s/.dm_forbidden_probe_%d.txt", home, (int)getpid());

    FILE* sf = fopen(sibling_secret, "wb");
    if (!sf) {
        fprintf(stderr, "failed to create sibling secret fixture\n");
        return 1;
    }
    fprintf(sf, "SIBLING_SECRET_DATA\n");
    fclose(sf);

    dm_sandbox_config_t cfg = {
        .template_path = tmpl,
        .prefixes_root = pfx_root,
        .target_prefix = pfx_alpha,
        .game_dir = game_dir,
        .shader_cache_dir = cache_dir,
        .output_dir = cache_dir,
        .user_home = home,
        .allow_network = false,
    };

    char err[512] = {0};
    if (!dm_sandbox_write_profile(&cfg, profile_path, err, sizeof(err))) {
        fprintf(stderr, "dm_sandbox_write_profile failed: %s\n", err);
        return 1;
    }

    char* child_argv[] = {
        argv[0],
        "--worker",
        target_write,
        cache_write,
        sibling_secret,
        home_ssh,
        forbidden_write,
        NULL,
    };
    const int rc = dm_sandbox_exec_profiled(profile_path, child_argv);

    /* Cleanup temp workspace */
    unlink(sibling_secret);
    unlink(target_write);
    unlink(cache_write);
    unlink(profile_path);
    rmdir(pfx_alpha);
    rmdir(pfx_beta);
    rmdir(pfx_root);
    rmdir(game_dir);
    rmdir(cache_dir);
    rmdir(test_root);

    if (rc != 0) {
        fprintf(stderr, "[dm_sandbox_test] FAILED (exit=%d)\n", rc);
        return 1;
    }
    printf("[dm_sandbox_test] PASSED: kernel Seatbelt isolation verified (5/5 assertions).\n");
    return 0;
}
