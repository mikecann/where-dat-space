#ifndef SPACE_SCAN_H
#define SPACE_SCAN_H
#include <stdint.h>
#include <stddef.h>
// Keep retained nodes at 40 bytes, including mtime and recursive count.
// Names fit PATH_MAX; counts above UINT32_MAX fail rather than silently wrap.
typedef struct {
    uint64_t size;
    int64_t modified;
    uint32_t count, parent, first_child, next_sibling, name_offset;
    uint16_t name_length, flags;
} SpaceNode;
typedef struct {
    uint64_t files, folders, bytes, unreadable, duplicates;
    double elapsed;
    char current_path[4096];
} SpaceProgress;
typedef struct SpaceScan SpaceScan;
SpaceScan *space_scan_create(const char *path, uint64_t threshold, int workers);
// Optional bounded list for folded files, which have no individual tree node.
void space_scan_set_largest(SpaceScan *scan, size_t limit);
size_t space_scan_small_largest_count(SpaceScan *scan);
uint32_t space_scan_small_largest_parent(SpaceScan *scan, size_t index);
const char *space_scan_small_largest_name(SpaceScan *scan, size_t index);
uint64_t space_scan_small_largest_size(SpaceScan *scan, size_t index);
uint32_t space_scan_small_largest_sharing(SpaceScan *scan, size_t index);
int64_t space_scan_small_largest_modified(SpaceScan *scan, size_t index);
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
