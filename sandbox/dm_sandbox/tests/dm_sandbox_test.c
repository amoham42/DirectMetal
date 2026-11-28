#undef NDEBUG
#include "dm_sandbox.h"

#include <assert.h>
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

static void write_fixture_file(const char* path, const char* content) {
    FILE* fp = fopen(path, "wb");
    assert(fp != NULL);
    const size_t len = strlen(content);
    assert(fwrite(content, 1, len, fp) == len);
    assert(fclose(fp) == 0);
}

static int assert_eperm_open(const char* path, int flags, const char* label) {
    errno = 0;
    int fd = open(path, flags, 0600);
    if (fd >= 0) {
        close(fd);
        fprintf(stderr, "FAIL: %s access WAS ALLOWED unexpectedly!\n", label);
        return 1;
    }
    if (errno != EPERM) {
        fprintf(stderr, "FAIL: %s returned errno=%d (%s) instead of EPERM\n",
                label, errno, strerror(errno));
        return 1;
    }
    printf("  [PASS] %s blocked by Seatbelt (EPERM)\n", label);
    return 0;
}

static int run_worker_checks(const char* mock_home) {
    int fails = 0;

    char target_write[1024], cache_write[1024], sibling_secret[1024];
    char ssh_key[1024], netrc_path[1024], npmrc_path[1024], pypirc_path[1024], aws_creds[1024];
    char forbidden_home_write[1024];

    snprintf(target_write, sizeof(target_write), "%s/prefixes/alpha/alpha_save.txt", mock_home);
    snprintf(cache_write, sizeof(cache_write), "%s/cache/pipeline.bin", mock_home);
    snprintf(sibling_secret, sizeof(sibling_secret), "%s/prefixes/beta/save_secret.txt", mock_home);
    snprintf(ssh_key, sizeof(ssh_key), "%s/.ssh/id_ed25519", mock_home);
    snprintf(netrc_path, sizeof(netrc_path), "%s/.netrc", mock_home);
    snprintf(npmrc_path, sizeof(npmrc_path), "%s/.npmrc", mock_home);
    snprintf(pypirc_path, sizeof(pypirc_path), "%s/.pypirc", mock_home);
    snprintf(aws_creds, sizeof(aws_creds), "%s/.aws/credentials", mock_home);
    snprintf(forbidden_home_write, sizeof(forbidden_home_write), "%s/forbidden_probe.txt", mock_home);

    /* 1. Target prefix RW must succeed */
    int fd = open(target_write, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "FAIL: target prefix write denied (%s)\n", strerror(errno));
        ++fails;
    } else {
        const char* ok = "prefix-rw-ok\n";
        if (write(fd, ok, strlen(ok)) < 0) ++fails;
        close(fd);
    }

    /* 2. Shader cache RW must succeed */
    fd = open(cache_write, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) {
        fprintf(stderr, "FAIL: cache write denied (%s)\n", strerror(errno));
        ++fails;
    } else {
        const char* ok = "cache-rw-ok\n";
        if (write(fd, ok, strlen(ok)) < 0) ++fails;
        close(fd);
    }

    /* 3. Sibling Wine prefix read MUST return EPERM */
    fails += assert_eperm_open(sibling_secret, O_RDONLY, "Sibling prefix read");

    /* 4. Sensitive credential files & directories in mock USER_HOME MUST return EPERM */
    fails += assert_eperm_open(ssh_key, O_RDONLY, "Sensitive ~/.ssh/id_ed25519 read");
    fails += assert_eperm_open(netrc_path, O_RDONLY, "Sensitive ~/.netrc read");
    fails += assert_eperm_open(netrc_path, O_WRONLY | O_APPEND, "Sensitive ~/.netrc write");
    fails += assert_eperm_open(npmrc_path, O_RDONLY, "Sensitive ~/.npmrc read");
    fails += assert_eperm_open(npmrc_path, O_WRONLY | O_APPEND, "Sensitive ~/.npmrc write");
    fails += assert_eperm_open(pypirc_path, O_RDONLY, "Sensitive ~/.pypirc read");
    fails += assert_eperm_open(aws_creds, O_RDONLY, "Sensitive ~/.aws/credentials read");

    /* 5. Unapproved write under HOME MUST return EPERM */
    errno = 0;
    fd = open(forbidden_home_write, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        close(fd);
        unlink(forbidden_home_write);
        fprintf(stderr, "FAIL: unapproved HOME write WAS ALLOWED unexpectedly!\n");
        ++fails;
    } else if (errno != EPERM) {
        fprintf(stderr, "FAIL: unapproved HOME write returned errno=%d (%s) instead of EPERM\n",
                errno, strerror(errno));
        ++fails;
    } else {
        printf("  [PASS] Unapproved HOME write blocked by Seatbelt (EPERM)\n");
    }

    return fails == 0 ? 0 : 1;
}

static void test_error_and_null_err_buf_guards(const dm_sandbox_config_t* base_cfg,
                                               const char* mock_home) {
    char render_buf[32768];
    char err[512];

    /* Null cfg / out_buf / undersized buffer with NULL err_buf (both cap=0 and cap>0) */
    assert(!dm_sandbox_render_profile(NULL, render_buf, sizeof(render_buf), NULL, 0));
    assert(!dm_sandbox_render_profile(NULL, render_buf, sizeof(render_buf), NULL, 64));
    assert(!dm_sandbox_render_profile(base_cfg, NULL, sizeof(render_buf), NULL, 64));
    assert(!dm_sandbox_render_profile(base_cfg, render_buf, 128, NULL, 64));
    err[0] = '\0';
    assert(!dm_sandbox_render_profile(base_cfg, render_buf, 128, err, sizeof(err)));
    assert(err[0] != '\0');

    /* Missing required config fields with NULL err_buf */
    dm_sandbox_config_t missing_cfg = *base_cfg;
    missing_cfg.template_path = NULL;
    assert(!dm_sandbox_render_profile(&missing_cfg, render_buf, sizeof(render_buf), NULL, 64));

    missing_cfg = *base_cfg;
    missing_cfg.prefixes_root = NULL;
    assert(!dm_sandbox_render_profile(&missing_cfg, render_buf, sizeof(render_buf), NULL, 64));

    /* Nonexistent template_path with NULL err_buf (cap=0 and cap>0) and non-null err_buf */
    dm_sandbox_config_t bad_tmpl_cfg = *base_cfg;
    bad_tmpl_cfg.template_path = "/tmp/dm_nonexistent_sandbox_template_999999.sb.tmpl";
    assert(!dm_sandbox_render_profile(&bad_tmpl_cfg, render_buf, sizeof(render_buf), NULL, 0));
    assert(!dm_sandbox_render_profile(&bad_tmpl_cfg, render_buf, sizeof(render_buf), NULL, 64));
    err[0] = '\0';
    assert(!dm_sandbox_render_profile(&bad_tmpl_cfg, render_buf, sizeof(render_buf), err, sizeof(err)));
    assert(strstr(err, "failed to open template") != NULL);

    char bad_profile_out[1024];
    snprintf(bad_profile_out, sizeof(bad_profile_out), "%s/should_not_exist.sb", mock_home);
    assert(!dm_sandbox_write_profile(&bad_tmpl_cfg, bad_profile_out, NULL, 0));
    assert(!dm_sandbox_write_profile(&bad_tmpl_cfg, bad_profile_out, NULL, 64));
    err[0] = '\0';
    assert(!dm_sandbox_write_profile(&bad_tmpl_cfg, bad_profile_out, err, sizeof(err)));
    assert(strstr(err, "failed to open template") != NULL);

    /* Oversized template (>16 KiB) rejection */
    char oversized_tmpl[1024];
    snprintf(oversized_tmpl, sizeof(oversized_tmpl), "%s/oversized.sb.tmpl", mock_home);
    FILE* big = fopen(oversized_tmpl, "wb");
    assert(big != NULL);
    for (int i = 0; i < 17000; ++i) {
        fputc(';', big);
    }
    fclose(big);
    dm_sandbox_config_t big_cfg = *base_cfg;
    big_cfg.template_path = oversized_tmpl;
    assert(!dm_sandbox_render_profile(&big_cfg, render_buf, sizeof(render_buf), NULL, 64));
    err[0] = '\0';
    assert(!dm_sandbox_render_profile(&big_cfg, render_buf, sizeof(render_buf), err, sizeof(err)));
    assert(strstr(err, "exceeds maximum size") != NULL);
    unlink(oversized_tmpl);

    /* Output buffer too small during substitution (passes >=256 guard, fails mid-render) */
    assert(!dm_sandbox_render_profile(base_cfg, render_buf, 300, NULL, 64));
    err[0] = '\0';
    assert(!dm_sandbox_render_profile(base_cfg, render_buf, 300, err, sizeof(err)));
    assert(strstr(err, "too small") != NULL);

    /* SBPL newline injection rejection */
    dm_sandbox_config_t inject_cfg = *base_cfg;
    inject_cfg.game_dir = "/tmp/evil\n(allow default)";
    assert(!dm_sandbox_render_profile(&inject_cfg, render_buf, sizeof(render_buf), NULL, 64));

    /* dm_sandbox_write_profile invalid/unwritable profile_path with NULL err_buf */
    assert(!dm_sandbox_write_profile(base_cfg, NULL, NULL, 64));
    assert(!dm_sandbox_write_profile(base_cfg, "", NULL, 64));
    assert(!dm_sandbox_write_profile(base_cfg, "/tmp/dm_missing_dir_999999/out.sb", NULL, 64));
    err[0] = '\0';
    assert(!dm_sandbox_write_profile(base_cfg, "/tmp/dm_missing_dir_999999/out.sb", err, sizeof(err)));
    assert(err[0] != '\0');

    /* Verify default user_home=NULL fallback resolves getenv("HOME") cleanly */
    if (getenv("HOME") != NULL) {
        dm_sandbox_config_t env_home_cfg = *base_cfg;
        env_home_cfg.user_home = NULL;
        assert(dm_sandbox_render_profile(&env_home_cfg, render_buf, sizeof(render_buf), NULL, 0));
        assert(strstr(render_buf, ".netrc") != NULL);
        assert(strstr(render_buf, ".npmrc") != NULL);
    }

    /* dm_sandbox_exec_profiled invalid arguments */
    char arg0[] = "/usr/bin/true";
    char* valid_argv[] = {arg0, NULL};
    char* empty_argv[] = {NULL};
    assert(dm_sandbox_exec_profiled(NULL, valid_argv) == -1);
    assert(dm_sandbox_exec_profiled("", valid_argv) == -1);
    assert(dm_sandbox_exec_profiled(bad_profile_out, NULL) == -1);
    assert(dm_sandbox_exec_profiled(bad_profile_out, empty_argv) == -1);

    printf("  [PASS] Null err_buf, invalid template & argument guards verified\n");
}

int main(int argc, char** argv) {
    if (argc >= 3 && strcmp(argv[1], "--worker") == 0) {
        return run_worker_checks(argv[2]);
    }

    const char* tmpl = (argc >= 2) ? argv[1] : "sandbox/profiles/directmetal_game.sb.tmpl";

    /* Use an isolated mock user_home in /tmp so we NEVER touch the real user's ~/.netrc or ~/.npmrc */
    char home_tmpl[] = "/tmp/dm_sandbox_home_XXXXXX";
    char* mock_home = mkdtemp(home_tmpl);
    if (!mock_home) {
        fprintf(stderr, "mkdtemp failed: %s\n", strerror(errno));
        return 1;
    }

    char pfx_root[1024], pfx_alpha[1024], pfx_beta[1024], game_dir[1024], cache_dir[1024];
    char ssh_dir[1024], aws_dir[1024], profile_path[1024];
    snprintf(pfx_root, sizeof(pfx_root), "%s/prefixes", mock_home);
    snprintf(pfx_alpha, sizeof(pfx_alpha), "%s/alpha", pfx_root);
    snprintf(pfx_beta, sizeof(pfx_beta), "%s/beta", pfx_root);
    snprintf(game_dir, sizeof(game_dir), "%s/game", mock_home);
    snprintf(cache_dir, sizeof(cache_dir), "%s/cache", mock_home);
    snprintf(ssh_dir, sizeof(ssh_dir), "%s/.ssh", mock_home);
    snprintf(aws_dir, sizeof(aws_dir), "%s/.aws", mock_home);
    snprintf(profile_path, sizeof(profile_path), "%s/test.sb", mock_home);

    assert(mkdir_p(pfx_alpha) == 0);
    assert(mkdir_p(pfx_beta) == 0);
    assert(mkdir_p(game_dir) == 0);
    assert(mkdir_p(cache_dir) == 0);
    assert(mkdir_p(ssh_dir) == 0);
    assert(mkdir_p(aws_dir) == 0);

    char sibling_secret[1024], target_write[1024], cache_write[1024];
    char ssh_key[1024], netrc_path[1024], npmrc_path[1024], pypirc_path[1024], aws_creds[1024];
    snprintf(sibling_secret, sizeof(sibling_secret), "%s/save_secret.txt", pfx_beta);
    snprintf(target_write, sizeof(target_write), "%s/alpha_save.txt", pfx_alpha);
    snprintf(cache_write, sizeof(cache_write), "%s/pipeline.bin", cache_dir);
    snprintf(ssh_key, sizeof(ssh_key), "%s/id_ed25519", ssh_dir);
    snprintf(netrc_path, sizeof(netrc_path), "%s/.netrc", mock_home);
    snprintf(npmrc_path, sizeof(npmrc_path), "%s/.npmrc", mock_home);
    snprintf(pypirc_path, sizeof(pypirc_path), "%s/.pypirc", mock_home);
    snprintf(aws_creds, sizeof(aws_creds), "%s/credentials", aws_dir);

    write_fixture_file(sibling_secret, "SIBLING_SECRET_DATA\n");
    write_fixture_file(ssh_key, "MOCK_SSH_PRIVATE_KEY\n");
    write_fixture_file(netrc_path, "machine api.example.com login mock password secret\n");
    write_fixture_file(npmrc_path, "//registry.npmjs.org/:_authToken=mock_token\n");
    write_fixture_file(pypirc_path, "[pypi]\npassword = mock_pypi_token\n");
    write_fixture_file(aws_creds, "[default]\naws_secret_access_key = mock_aws_secret\n");

    dm_sandbox_config_t cfg = {
        .template_path = tmpl,
        .prefixes_root = pfx_root,
        .target_prefix = pfx_alpha,
        .game_dir = game_dir,
        .shader_cache_dir = cache_dir,
        .output_dir = cache_dir,
        .user_home = mock_home,
        .allow_network = false,
    };

    test_error_and_null_err_buf_guards(&cfg, mock_home);

    char err[512] = {0};
    if (!dm_sandbox_write_profile(&cfg, profile_path, err, sizeof(err))) {
        fprintf(stderr, "dm_sandbox_write_profile failed: %s\n", err);
        return 1;
    }

    char worker_flag[] = "--worker";
    char* child_argv[] = {
        argv[0],
        worker_flag,
        mock_home,
        NULL,
    };
    const int rc = dm_sandbox_exec_profiled(profile_path, child_argv);

    /* Cleanup isolated mock workspace */
    unlink(sibling_secret);
    unlink(target_write);
    unlink(cache_write);
    unlink(ssh_key);
    unlink(netrc_path);
    unlink(npmrc_path);
    unlink(pypirc_path);
    unlink(aws_creds);
    unlink(profile_path);
    rmdir(pfx_alpha);
    rmdir(pfx_beta);
    rmdir(pfx_root);
    rmdir(game_dir);
    rmdir(cache_dir);
    rmdir(ssh_dir);
    rmdir(aws_dir);
    rmdir(mock_home);

    if (rc != 0) {
        fprintf(stderr, "[dm_sandbox_test] FAILED (exit=%d)\n", rc);
        return 1;
    }
    printf("[dm_sandbox_test] PASSED: kernel Seatbelt isolation & API guards verified.\n");
    return 0;
}
