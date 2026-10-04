// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef IRAR_ARCHIVE_BRIDGE_H
#define IRAR_ARCHIVE_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
// Returning nonzero cancels. entry=1 emits metadata, entry=0 reports progress.
// Strings are valid only during the callback. bytes is extracted bytes, input is
// compressed bytes consumed; size=-1 means unknown. No callbacks on UI thread.
typedef int (*irar_archive_callback)(void *, const char *name, const char *format,
    int64_t size, int directory, int entry, int64_t bytes, int64_t input);
// Newline-separated volume paths (reject newline-containing filenames). Null
// destination inspects; otherwise extraction is exclusive, never overwriting.
// Results: 0 success, 1 cancelled, -1 useful error in error buffer.
int irar_archive_run(const char *volumes, const char *allowed_root, const char *destination,
    irar_archive_callback callback, void *context, char *error, size_t capacity);
#endif
