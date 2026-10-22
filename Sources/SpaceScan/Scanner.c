#include "SpaceScan.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>

#define NONE UINT32_MAX
#define DIRECTORY 1u
#define SMALL_FILES 2u
#define UNREADABLE 4u
#define QUEUE_INITIAL 1024
// Bulk metadata avoids a syscall and Swift allocation for every file.
#define BULK_BYTES (64 * 1024)
typedef struct { uint64_t inode; dev_t device; } LinkKey;
typedef struct { uint32_t index; int fd; } DirectoryJob;
typedef struct { uint32_t index; const char *name; } PendingDirectory;
struct SpaceScan {
    pthread_mutex_t lock;
    pthread_cond_t ready;
    atomic_bool cancelled;
    SpaceNode *nodes; size_t node_count, node_capacity;
    char *names; size_t names_count, names_capacity;
    DirectoryJob *queue; size_t queue_count, queue_capacity;
    size_t queued_descriptors, descriptor_limit, eviction_cursor;
    int active, workers, error;
    dev_t device;
    char *root;
    uint64_t threshold;
    LinkKey *links; size_t link_count, link_capacity;
    SpaceProgress progress;
    struct timespec started;
};
static double seconds_since(struct timespec start) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9;
}
static void *grow(void *buffer, size_t *capacity, size_t need, size_t width) {
    if (need <= *capacity) return buffer;
    size_t cap = *capacity ? *capacity * 2 : 1024;
    while (cap < need) cap *= 2;
    void *new_buffer = realloc(buffer, cap * width);
    if (!new_buffer) abort();
    *capacity = cap; return new_buffer;
}
// Caller holds the lock. Append-only indices make final bottom-up totals linear.
static uint32_t add_node(SpaceScan *s, uint32_t parent, const char *name, uint64_t size, uint32_t flags, uint32_t count) {
    size_t length = strlen(name);
    if (s->node_count >= NONE || s->names_count + length >= NONE) { s->error = EOVERFLOW; atomic_store(&s->cancelled, 1); return NONE; }
    s->nodes = grow(s->nodes, &s->node_capacity, s->node_count + 1, sizeof(SpaceNode));
    s->names = grow(s->names, &s->names_capacity, s->names_count + length, 1);
    uint32_t i = (uint32_t)s->node_count++;
    SpaceNode n = { .size=size, .parent=parent, .first_child=NONE, .next_sibling=NONE,
        .name_offset=(uint32_t)s->names_count, .name_length=(uint32_t)length, .flags=flags, .count=count };
    memcpy(s->names + s->names_count, name, length); s->names_count += length;
    if (parent != NONE) { n.next_sibling = s->nodes[parent].first_child; s->nodes[parent].first_child = i; }
    s->nodes[i] = n; return i;
}
static void enqueue(SpaceScan *s, uint32_t node, int fd) {
    if (node == NONE) return;
    s->queue = grow(s->queue, &s->queue_capacity, s->queue_count + 1, sizeof(DirectoryJob));
    s->queue[s->queue_count++] = (DirectoryJob){node,fd};
}
static char *node_path(SpaceScan *s, uint32_t node) {
    size_t length = strlen(s->root);
    for (uint32_t i=node; i; i=s->nodes[i].parent) length += 1 + s->nodes[i].name_length;
    char *path = malloc(length + 1); if (!path) abort(); path[length] = 0;
    size_t pos = length;
    for (uint32_t i=node; i; i=s->nodes[i].parent) {
        SpaceNode n = s->nodes[i]; pos -= n.name_length;
        memcpy(path + pos, s->names + n.name_offset, n.name_length); path[--pos] = '/';
    }
    memcpy(path, s->root, strlen(s->root)); return path;
}
static size_t link_hash(uint64_t inode, dev_t device) {
    uint64_t v = inode ^ ((uint64_t)device << 32); v ^= v >> 33; v *= 0xff51afd7ed558ccdULL; return v ^ (v >> 33);
}
static int duplicate_link(SpaceScan *s, uint64_t inode, dev_t device) {
    if (!s->link_capacity || s->link_count * 2 >= s->link_capacity) {
        size_t old_cap=s->link_capacity; LinkKey *old=s->links;
        s->link_capacity = old_cap ? old_cap * 2 : 4096;
        s->links = calloc(s->link_capacity, sizeof(LinkKey)); if (!s->links) abort();
        for (size_t i=0; i<old_cap; i++) if (old[i].inode) {
            size_t slot=link_hash(old[i].inode, old[i].device) & (s->link_capacity-1);
            while (s->links[slot].inode) slot=(slot+1)&(s->link_capacity-1);
            s->links[slot]=old[i];
        }
        free(old);
    }
    size_t slot=link_hash(inode, device)&(s->link_capacity-1);
    while (s->links[slot].inode) {
        if (s->links[slot].inode==inode && s->links[slot].device==device) return 1;
        slot=(slot+1)&(s->link_capacity-1);
    }
    s->links[slot]=(LinkKey){inode,device}; s->link_count++; return 0;
}
static void unreadable(SpaceScan *s, uint32_t index) {
    if (!(s->nodes[index].flags & UNREADABLE)) { s->nodes[index].flags |= UNREADABLE; s->progress.unreadable++; }
}
typedef struct { uint64_t bytes; uint32_t count; } Small;
static uint32_t entry(SpaceScan *s, uint32_t parent, const char *name, uint32_t type, uint64_t size,
                  uint32_t links, uint64_t inode, dev_t device, uint32_t error, Small *small) {
    if (!strcmp(name,".") || !strcmp(name,"..")) return NONE;
    if (type == VDIR) {
        if (device != s->device) return NONE;
        uint32_t child=add_node(s,parent,name,0,DIRECTORY,0);
        s->progress.folders++;
        if (child == NONE) return NONE;
        if (error) unreadable(s,child); else return child;
    } else if (type == VREG) {
        s->progress.files++;
        if (links > 1 && duplicate_link(s,inode,device)) { s->progress.duplicates++; return NONE; }
        if (error) { unreadable(s,parent); return NONE; }
        s->progress.bytes += size;
        if (size >= s->threshold) add_node(s,parent,name,size,0,1);
        else { small->bytes += size; small->count++; }
    } else if (error) unreadable(s,parent);
    return NONE;
}
// Keep a bounded number of open child directories. Most work can then use
// openat rather than resolving every ancestor for millions of deep paths.
static void schedule_child(SpaceScan *s, int parent_fd, uint32_t index, const char *name) {
    if (index == NONE || atomic_load(&s->cancelled)) return;
    pthread_mutex_lock(&s->lock);
    int evicted_fd=-1;
    // The work stack is depth-first. Give its newest jobs the cached handles,
    // rather than letting old siblings occupy the entire cache indefinitely.
    if (s->queued_descriptors >= s->descriptor_limit && s->queue_count) {
        for (size_t checked=0; checked<s->queue_count; checked++) {
            size_t slot=s->eviction_cursor++ % s->queue_count;
            if (s->queue[slot].fd >= 0) {
                evicted_fd=s->queue[slot].fd; s->queue[slot].fd=-1;
                s->queued_descriptors--; break;
            }
        }
    }
    int reserve = s->queued_descriptors < s->descriptor_limit;
    if (reserve) s->queued_descriptors++;
    pthread_mutex_unlock(&s->lock);
    if (evicted_fd >= 0) close(evicted_fd);
    int fd = reserve ? openat(parent_fd,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC) : -1;
    int open_error=errno;
    pthread_mutex_lock(&s->lock);
    if (reserve && fd < 0) {
        s->queued_descriptors--;
        if (open_error==EMFILE || open_error==ENFILE) enqueue(s,index,-1);
        else unreadable(s,index);
    } else enqueue(s,index,fd);
    pthread_cond_signal(&s->ready);
    pthread_mutex_unlock(&s->lock);
}
#define READ_VALUE(dst) do { memcpy(&(dst), cursor, sizeof(dst)); cursor += sizeof(dst); } while(0)
static int scan_bulk(SpaceScan *s, int fd, uint32_t parent, Small *small, char *buffer) {
    struct attrlist attrs = { .bitmapcount=ATTR_BIT_MAP_COUNT,
        .commonattr=ATTR_CMN_RETURNED_ATTRS|ATTR_CMN_ERROR|ATTR_CMN_NAME|ATTR_CMN_DEVID|ATTR_CMN_OBJTYPE|ATTR_CMN_FILEID,
        .fileattr=ATTR_FILE_LINKCOUNT|ATTR_FILE_ALLOCSIZE };
    int count;
    while (!atomic_load(&s->cancelled) && (count=getattrlistbulk(fd,&attrs,buffer,BULK_BYTES,FSOPT_PACK_INVAL_ATTRS)) > 0) {
        char *record=buffer;
        PendingDirectory pending[BULK_BYTES / 32]; size_t pending_count=0;
        pthread_mutex_lock(&s->lock);
        for (int i=0; i<count; i++) {
            const char *cursor=record; uint32_t length, error, type, links; uint64_t inode; off_t allocated; dev_t device;
            attribute_set_t returned; attrreference_t name;
            READ_VALUE(length); READ_VALUE(returned); READ_VALUE(error);
            const char *name_base=cursor; READ_VALUE(name); READ_VALUE(device); READ_VALUE(type); READ_VALUE(inode);
            READ_VALUE(links); READ_VALUE(allocated);
            const char *filename=name_base+name.attr_dataoffset;
            if (!(returned.commonattr & ATTR_CMN_DEVID)) device=s->device;
            // Some non-APFS volumes return only a subset of the requested fields.
            // Never silently treat an unsupported allocation attribute as zero.
            if (!error && (!(returned.commonattr & ATTR_CMN_OBJTYPE) ||
                (type==VREG && (!(returned.commonattr & ATTR_CMN_FILEID) ||
                (returned.fileattr & (ATTR_FILE_LINKCOUNT|ATTR_FILE_ALLOCSIZE)) != (ATTR_FILE_LINKCOUNT|ATTR_FILE_ALLOCSIZE))))) {
                struct stat info;
                if (!fstatat(fd,filename,&info,AT_SYMLINK_NOFOLLOW)) {
                    type=S_ISDIR(info.st_mode)?VDIR:S_ISREG(info.st_mode)?VREG:VLNK;
                    allocated=info.st_blocks*512; links=info.st_nlink; inode=info.st_ino; device=info.st_dev;
                } else error=errno;
            }
            uint32_t child=entry(s,parent,filename,type,allocated > 0 ? (uint64_t)allocated : 0,links,inode,device,error,small);
            if (child != NONE) pending[pending_count++]=(PendingDirectory){child,filename};
            record += length;
        }
        pthread_mutex_unlock(&s->lock);
        for (size_t i=0;i<pending_count;i++) schedule_child(s,fd,pending[i].index,pending[i].name);
    }
    return atomic_load(&s->cancelled) ? 0 : count;
}
// A fallback keeps non-APFS filesystems usable when bulk metadata isn't supported.
static void scan_fallback(SpaceScan *s, int fd, uint32_t parent, Small *small) {
    lseek(fd,0,SEEK_SET); DIR *dir=fdopendir(dup(fd)); if (!dir) return;
    struct dirent *item;
    while (!atomic_load(&s->cancelled) && (item=readdir(dir))) {
        struct stat st;
        if (fstatat(fd,item->d_name,&st,AT_SYMLINK_NOFOLLOW)) {
            pthread_mutex_lock(&s->lock); unreadable(s,parent); pthread_mutex_unlock(&s->lock); continue;
        }
        uint32_t type=S_ISDIR(st.st_mode)?VDIR:S_ISREG(st.st_mode)?VREG:VLNK;
        pthread_mutex_lock(&s->lock);
        uint32_t child=entry(s,parent,item->d_name,type,(uint64_t)st.st_blocks*512,st.st_nlink,st.st_ino,st.st_dev,0,small);
        pthread_mutex_unlock(&s->lock);
        schedule_child(s,fd,child,item->d_name);
    }
    closedir(dir);
}
static void *worker(void *context) {
    SpaceScan *s=context; char *buffer=malloc(BULK_BYTES); uint64_t processed=0;
    for (;;) {
        pthread_mutex_lock(&s->lock);
        while (!s->queue_count && s->active && !atomic_load(&s->cancelled)) pthread_cond_wait(&s->ready,&s->lock);
        if (atomic_load(&s->cancelled) || !s->queue_count) { pthread_mutex_unlock(&s->lock); break; }
        DirectoryJob job=s->queue[--s->queue_count]; uint32_t index=job.index; s->active++;
        if (job.fd >= 0) s->queued_descriptors--;
        char *path = job.fd < 0 || processed++ % 128 == 0 ? node_path(s,index) : NULL;
        if (path) snprintf(s->progress.current_path,sizeof(s->progress.current_path),"%s",path);
        pthread_mutex_unlock(&s->lock);
        int fd=job.fd >= 0 ? job.fd : open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC); struct stat st; Small small={0};
        int failure=fd<0;
        if (fd>=0) {
            if (fstat(fd,&st)) failure=1;
            else if (st.st_dev==s->device) {
                // Honour mode 000 even when tests run as an administrator/root.
                if (!(st.st_mode & 0444)) failure=1;
                else if (scan_bulk(s,fd,index,&small,buffer)<0) {
                    if (errno==ENOTSUP || errno==EINVAL || errno==ENOSYS) scan_fallback(s,fd,index,&small);
                    else failure=1;
                }
            }
            close(fd);
        }
        free(path);
        pthread_mutex_lock(&s->lock);
        if (failure) unreadable(s,index);
        if (small.count) add_node(s,index,"",small.bytes,SMALL_FILES,small.count);
        s->active--; pthread_cond_broadcast(&s->ready); pthread_mutex_unlock(&s->lock);
    }
    free(buffer); return NULL;
}
SpaceScan *space_scan_create(const char *path, uint64_t threshold, int workers) {
    SpaceScan *s=calloc(1,sizeof(SpaceScan)); if (!s) return NULL;
    pthread_mutex_init(&s->lock,NULL); pthread_cond_init(&s->ready,NULL); atomic_init(&s->cancelled,0);
    s->root=strdup(path); size_t length=strlen(s->root); while(length>1 && s->root[length-1]=='/') s->root[--length]=0;
    struct rlimit descriptor_budget; getrlimit(RLIMIT_NOFILE,&descriptor_budget);
    s->descriptor_limit=descriptor_budget.rlim_cur > 192 ? descriptor_budget.rlim_cur-128 : descriptor_budget.rlim_cur/4;
    if (s->descriptor_limit > 256) s->descriptor_limit=256;
    if (s->descriptor_limit < 4) s->descriptor_limit=4;
    s->threshold=threshold; s->workers=workers<1?1:workers>16?16:workers;
    struct stat st;
    if (lstat(s->root,&st)) s->error=errno;
    else if (!S_ISDIR(st.st_mode)) s->error=ENOTDIR;
    else s->device=st.st_dev;
    add_node(s,NONE,s->root,0,DIRECTORY,0); enqueue(s,0,-1); s->progress.folders=1;
    clock_gettime(CLOCK_MONOTONIC,&s->started); return s;
}
int space_scan_run(SpaceScan *s) {
    if (s->error) return s->error;
    pthread_t threads[16]; int created=0;
    for(int i=0;i<s->workers;i++) if (!pthread_create(&threads[created],NULL,worker,s)) created++;
    if (!created) worker(s);
    for(int i=0;i<created;i++) pthread_join(threads[i],NULL);
    for(size_t i=s->node_count;i-->1;) s->nodes[s->nodes[i].parent].size += s->nodes[i].size;
    s->progress.elapsed=seconds_since(s->started);
    return s->error;
}
void space_scan_cancel(SpaceScan *s) { atomic_store(&s->cancelled,1); pthread_mutex_lock(&s->lock); pthread_cond_broadcast(&s->ready); pthread_mutex_unlock(&s->lock); }
void space_scan_progress(SpaceScan *s, SpaceProgress *p) { pthread_mutex_lock(&s->lock); *p=s->progress; p->elapsed=seconds_since(s->started); pthread_mutex_unlock(&s->lock); }
const SpaceNode *space_scan_nodes(SpaceScan *s) { return s->nodes; }
size_t space_scan_node_count(SpaceScan *s) { return s->node_count; }
const char *space_scan_names(SpaceScan *s) { return s->names; }
size_t space_scan_names_count(SpaceScan *s) { return s->names_count; }
int space_scan_error(SpaceScan *s) { return s->error; }
void space_scan_destroy(SpaceScan *s) { if (!s) return; for (size_t i=0;i<s->queue_count;i++) if(s->queue[i].fd>=0) close(s->queue[i].fd); pthread_mutex_destroy(&s->lock); pthread_cond_destroy(&s->ready); free(s->nodes); free(s->names); free(s->root); free(s->queue); free(s->links); free(s); }
uint64_t space_peak_memory(void) { struct rusage usage; getrusage(RUSAGE_SELF,&usage); return (uint64_t)usage.ru_maxrss; }
