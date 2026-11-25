#include "dm_prefix.h"

#include <assert.h>
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
    char meta_buf[512];
    read_file_str(meta_file, meta_buf, sizeof(meta_buf));
    assert(strstr(meta_buf, "apple7_25B78") != NULL);

    char names[8][256];
    size_t count = 0;
    assert(dm_prefix_list(prefixes_dir, names, 8, &count) == 0);
    assert(count == 1 && strcmp(names[0], "game_alpha") == 0);

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
