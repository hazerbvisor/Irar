// SPDX-License-Identifier: GPL-3.0-or-later

#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1 // Expose O_NOFOLLOW alongside POSIX APIs on Darwin.
#endif
#include "ArchiveBridge.h"
#include <archive.h>
#include <archive_entry.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Never pass archive paths to a path-based writer. Every component is opened
// relative to a held directory descriptor, refusing symlinks at each step.
static int safe_name(const char *s) {
    if (!s || !*s || strnlen(s, 4097) > 4096 || *s == '/' || strchr(s, '\\') || strchr(s, ':')) return 0;
    const char *p = s;
    while (*p) {
        const char *end = strchr(p, '/');
        size_t n = end ? (size_t)(end - p) : strlen(p);
        if (!n || (n == 1 && p[0] == '.') || (n == 2 && p[0] == '.' && p[1] == '.')) return 0;
        p += n; if (*p) ++p;
    }
    return 1;
}
static int parent_fd(int root, char *name, char **leaf) {
    int fd = dup(root); if (fd < 0) return -1;
    char *p = name, *slash;
    while ((slash = strchr(p, '/'))) {
        *slash = 0;
        if (mkdirat(fd, p, 0755) < 0 && errno != EEXIST) { close(fd); return -1; }
        int next = openat(fd, p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); if (next < 0) return -1;
        fd = next; p = slash + 1;
    }
    *leaf = p; return fd;
}
int irar_archive_run(const char *volumes, const char *allowed_root, const char *destination,
    irar_archive_callback cb, void *ctx, char *error, size_t cap) {
    int result = -1, root = -1, output = -1, parent = -1;
    char *names = NULL, *path = NULL, *leaf = NULL;
    const char **files = NULL;
    struct archive *a = archive_read_new();
    if (!a) { snprintf(error, cap, "Unable to allocate archive reader."); return -1; }
    if (cap) error[0] = 0;
    archive_read_support_filter_none(a); // no external decompressor fallback
    archive_read_support_format_zip(a);
    // RAR/RAR5 plus standard ZIP; no optional external codec dependency.
    archive_read_support_format_rar(a);
    archive_read_support_format_rar5(a);
    names = strdup(volumes);
    if (!names) goto done;
    size_t count = 2;
    for (const char *p = volumes; *p; ++p) if (*p == '\n') ++count;
    files = calloc(count, sizeof(*files)); if (!files) goto done;
    char *save = NULL; size_t i = 0;
    for (char *p = strtok_r(names, "\n", &save); p; p = strtok_r(NULL, "\n", &save)) files[i++] = p;
    if (!i) { snprintf(error, cap, "No archive selected."); goto done; }
    if (destination) {
        if (!allowed_root) { snprintf(error, cap, "Missing app storage root."); goto done; }
        size_t base = strlen(allowed_root);
        if (strncmp(destination, allowed_root, base) || (destination[base] && destination[base] != '/')) {
            snprintf(error, cap, "Extraction folder leaves app storage."); goto done;
        }
        root = open(allowed_root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (root < 0) { snprintf(error, cap, "Cannot open app storage: %s", strerror(errno)); goto done; }
        if (destination[base]) {
            const char *relative = destination + base + 1;
            if (!safe_name(relative)) { snprintf(error, cap, "Unsafe extraction folder."); goto done; }
            char *dirs = strdup(relative), *saved = NULL;
            if (!dirs) goto done;
            for (char *part = strtok_r(dirs, "/", &saved); part; part = strtok_r(NULL, "/", &saved)) {
                int next = openat(root, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                close(root); root = next;
                if (root < 0) break;
            }
            free(dirs);
            if (root < 0) { snprintf(error, cap, "Unsafe or inaccessible extraction folder."); goto done; }
        }
    }
    if (archive_read_open_filenames(a, files, 65536) != ARCHIVE_OK) goto archive_error;
    struct archive_entry *entry;
    int status; int64_t bytes = 0;
    unsigned char buffer[65536];
    for (;;) {
        if (cb(ctx, "", "", -1, 0, 0, bytes, archive_filter_bytes(a, -1))) { result = 1; goto done; }
        status = archive_read_next_header(a, &entry);
        if (status == ARCHIVE_EOF) break;
        if (status != ARCHIVE_OK) goto archive_error;
        const char *name = archive_entry_pathname_utf8(entry);
        if (!name) name = archive_entry_pathname(entry);
        mode_t type = archive_entry_filetype(entry);
        if (!safe_name(name) || archive_entry_symlink(entry) || archive_entry_hardlink(entry) ||
            (type != AE_IFREG && type != AE_IFDIR)) {
            snprintf(error, cap, "Unsafe archive entry rejected: %s", name ? name : "(unnamed)"); goto done;
        }
        if (archive_entry_is_encrypted(entry) > 0) {
            snprintf(error, cap, "Encrypted archives are not supported."); goto done;
        }
        int64_t size = archive_entry_size_is_set(entry) ? archive_entry_size(entry) : -1;
        const char *format = archive_format_name(a);
        if (cb(ctx, name, format ? format : "Archive", size, type == AE_IFDIR, 1, bytes, archive_filter_bytes(a, -1))) {
            result = 1; goto done;
        }
        if (!destination) {
            if (archive_read_data_skip(a) != ARCHIVE_OK) goto archive_error;
            continue;
        }
        path = strdup(name); if (!path) goto done;
        size_t len = strlen(path);
        if (len && path[len - 1] == '/') path[len - 1] = 0;
        parent = parent_fd(root, path, &leaf);
        if (parent < 0) { snprintf(error, cap, "Unsafe or inaccessible parent folder: %s", name); goto done; }
        if (type == AE_IFDIR) {
            if (mkdirat(parent, leaf, 0755) < 0 && errno != EEXIST) goto file_error;
            int dir = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (dir < 0) goto file_error;
            close(dir);
        } else {
            output = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
            if (output < 0) goto file_error;
            for (;;) {
                if (cb(ctx, name, format, size, 0, 0, bytes, archive_filter_bytes(a, -1))) { result = 1; goto done; }
                la_ssize_t n = archive_read_data(a, buffer, sizeof(buffer));
                if (n < 0) goto archive_error;
                if (!n) break;
                size_t written = 0;
                while (written < (size_t)n) {
                    ssize_t w = write(output, buffer + written, (size_t)n - written);
                    if (w < 0 && errno == EINTR) continue;
                    if (w <= 0) goto file_error;
                    written += (size_t)w;
                }
                bytes += n;
            }
            if (close(output) < 0) { output = -1; unlinkat(parent, leaf, 0); goto file_error; }
            output = -1;
        }
        close(parent); parent = -1; free(path); path = NULL;
    }
    if (cb(ctx, "", archive_format_name(a), -1, 0, 0, bytes, archive_filter_bytes(a, -1))) { result = 1; goto done; }
    result = 0; goto done;
archive_error:
    snprintf(error, cap, "Archive error: %s", archive_error_string(a) ? archive_error_string(a) : "invalid or unsupported archive");
    goto done;
file_error:
    snprintf(error, cap, "Cannot extract %s: %s. Existing files are never overwritten; choose a new folder.", archive_entry_pathname(entry), strerror(errno));
done:
    // Keep completed files, remove only this operation's incomplete file.
    if (output >= 0) { close(output); if (parent >= 0 && leaf) unlinkat(parent, leaf, 0); }
    if (parent >= 0) close(parent);
    if (root >= 0) close(root);
    if (result < 0 && cap && !error[0]) snprintf(error, cap, "Unable to allocate archive resources.");
    archive_read_free(a); free(files); free(names); free(path);
    return result;
}
