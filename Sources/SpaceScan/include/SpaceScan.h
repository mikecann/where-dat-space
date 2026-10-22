#ifndef SPACE_SCAN_H
#define SPACE_SCAN_H
#include <stdint.h>
#include <stddef.h>
// Indices and name offsets stay 32-bit; no per-file strings or heap objects.
typedef struct {
    uint64_t size;
    uint32_t parent, first_child, next_sibling, name_offset, name_length, count, flags;
} SpaceNode;
typedef struct {
    uint64_t files, folders, bytes, unreadable, duplicates;
    double elapsed;
    char current_path[4096];
} SpaceProgress;
typedef struct SpaceScan SpaceScan;
SpaceScan *space_scan_create(const char *path, uint64_t threshold, int workers);
int space_scan_run(SpaceScan *scan);
void space_scan_cancel(SpaceScan *scan);
void space_scan_progress(SpaceScan *scan, SpaceProgress *progress);
const SpaceNode *space_scan_nodes(SpaceScan *scan);
size_t space_scan_node_count(SpaceScan *scan);
const char *space_scan_names(SpaceScan *scan);
size_t space_scan_names_count(SpaceScan *scan);
int space_scan_error(SpaceScan *scan);
void space_scan_destroy(SpaceScan *scan);
uint64_t space_peak_memory(void);
#endif
