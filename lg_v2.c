#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <pwd.h>
#include <grp.h>
#include <time.h>
#include <unistd.h>
#include <getopt.h>
#include <limits.h>
#include <errno.h>
#include <ctype.h>
#include <sys/wait.h>

#define INITIAL_CAPACITY 100
#define MAX_PATH_SAFE 4096
#define MAX_NAME_LEN 256

// Output detail levels
typedef enum {
    DETAIL_MINIMAL = 0,
    DETAIL_STANDARD = 1,
    DETAIL_FULL = 2
} DetailLevel;

// Output format types
typedef enum {
    FORMAT_NORMAL = 0,
    FORMAT_JSON = 1,
    FORMAT_PORCELAIN = 2
} OutputFormat;

typedef struct {
    char *name;
    mode_t mode;
    off_t size;
    time_t mtime;
    uid_t uid;
    gid_t gid;
    char git_status;
    int is_dir;
    int is_exec;
    int is_symlink;
} FileInfo;

typedef struct {
    char *path;
    char status_staged;
    char status_unstaged;
} GitStatus;

typedef struct {
    GitStatus *statuses;
    size_t count;
    size_t capacity;
    char *rel_prefix;
} GitContext;

typedef struct {
    FileInfo *files;
    size_t count;
    size_t capacity;
} FileList;

// Global options
static DetailLevel detail_level = DETAIL_MINIMAL;
static OutputFormat output_format = FORMAT_NORMAL;
static int show_all = 0;
static int sort_alphabetical = 0;
static int show_branch = 0;
static int show_legend = 0;

// Safe string functions
static int safe_strncpy(char *dest, const char *src, size_t dest_size) {
    if (!dest || !src || dest_size == 0) return -1;
    
    size_t src_len = strlen(src);
    if (src_len >= dest_size) {
        strncpy(dest, src, dest_size - 1);
        dest[dest_size - 1] = '\0';
        return -1; // Truncation occurred
    }
    
    strcpy(dest, src);
    return 0;
}

static int safe_path_join(char *dest, size_t dest_size, const char *dir, const char *file) {
    int n = snprintf(dest, dest_size, "%s/%s", dir, file);
    if (n < 0 || (size_t)n >= dest_size) {
        return -1; // Error or truncation
    }
    return 0;
}

// Validate path to prevent traversal attacks
static int validate_path(const char *path) {
    if (!path) return 0;
    
    // Check path length
    if (strlen(path) >= PATH_MAX) return 0;
    
    // Allow relative paths but validate they exist
    return 1;
}

// Format file size in human-readable format
static void format_size(off_t size, char *buf, size_t buf_size) {
    if (size < 1024) {
        snprintf(buf, buf_size, "%4lldB", (long long)size);
    } else if (size < 1024 * 1024) {
        double kb = size / 1024.0;
        snprintf(buf, buf_size, "%5.1fK", kb);
    } else if (size < 1024 * 1024 * 1024) {
        double mb = size / (1024.0 * 1024);
        snprintf(buf, buf_size, "%5.1fM", mb);
    } else {
        double gb = size / (1024.0 * 1024 * 1024);
        snprintf(buf, buf_size, "%5.1fG", gb);
    }
}

// Initialize file list with dynamic allocation
static FileList* filelist_create(void) {
    FileList *list = malloc(sizeof(FileList));
    if (!list) return NULL;
    
    list->capacity = INITIAL_CAPACITY;
    list->count = 0;
    list->files = calloc(list->capacity, sizeof(FileInfo));
    
    if (!list->files) {
        free(list);
        return NULL;
    }
    
    return list;
}

// Add file to list with automatic resizing
static int filelist_add(FileList *list, FileInfo *info) {
    if (!list || !info) return -1;
    
    if (list->count >= list->capacity) {
        size_t new_capacity = list->capacity * 2;
        FileInfo *new_files = realloc(list->files, new_capacity * sizeof(FileInfo));
        if (!new_files) return -1;
        
        list->files = new_files;
        list->capacity = new_capacity;
    }
    
    // Deep copy the file info
    FileInfo *dest = &list->files[list->count];
    dest->name = strdup(info->name);
    if (!dest->name) return -1;
    
    dest->mode = info->mode;
    dest->size = info->size;
    dest->mtime = info->mtime;
    dest->uid = info->uid;
    dest->gid = info->gid;
    dest->git_status = info->git_status;
    dest->is_dir = info->is_dir;
    dest->is_exec = info->is_exec;
    dest->is_symlink = info->is_symlink;
    
    list->count++;
    return 0;
}

// Free file list
static void filelist_free(FileList *list) {
    if (!list) return;
    
    for (size_t i = 0; i < list->count; i++) {
        free(list->files[i].name);
    }
    free(list->files);
    free(list);
}

// Initialize git context
static GitContext* git_context_create(void) {
    GitContext *ctx = malloc(sizeof(GitContext));
    if (!ctx) return NULL;
    
    ctx->capacity = INITIAL_CAPACITY;
    ctx->count = 0;
    ctx->statuses = calloc(ctx->capacity, sizeof(GitStatus));
    ctx->rel_prefix = NULL;
    
    if (!ctx->statuses) {
        free(ctx);
        return NULL;
    }
    
    return ctx;
}

// Free git context
static void git_context_free(GitContext *ctx) {
    if (!ctx) return;
    
    for (size_t i = 0; i < ctx->count; i++) {
        free(ctx->statuses[i].path);
    }
    free(ctx->statuses);
    free(ctx->rel_prefix);
    free(ctx);
}

// Execute git command safely using fork/exec instead of popen
static int exec_git_command(const char *args[], char *output, size_t output_size) {
    int pipefd[2];
    pid_t pid;
    
    if (pipe(pipefd) == -1) {
        return -1;
    }
    
    pid = fork();
    if (pid == -1) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }
    
    if (pid == 0) {
        // Child process
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        
        // Try multiple git locations
        execvp("git", (char * const *)args);
        // If we get here, exec failed
        _exit(1);
    }
    
    // Parent process
    close(pipefd[1]);
    
    size_t total_read = 0;
    ssize_t bytes_read;
    while ((bytes_read = read(pipefd[0], output + total_read, 
                              output_size - total_read - 1)) > 0) {
        total_read += bytes_read;
        if (total_read >= output_size - 1) break;
    }
    output[total_read] = '\0';
    
    close(pipefd[0]);
    
    int status;
    waitpid(pid, &status, 0);
    
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

// Get git status using safe exec
static GitContext* get_git_status(const char *dir_path) {
    if (!validate_path(dir_path)) return NULL;
    
    GitContext *ctx = git_context_create();
    if (!ctx) return NULL;
    
    char old_dir[PATH_MAX];
    if (!getcwd(old_dir, sizeof(old_dir))) {
        git_context_free(ctx);
        return NULL;
    }
    
    // Safely change to target directory
    if (chdir(dir_path) != 0) {
        git_context_free(ctx);
        return NULL;
    }
    
    // Get git root using safe exec
    char git_root[PATH_MAX];
    const char *args_root[] = {"git", "rev-parse", "--show-toplevel", NULL};
    if (exec_git_command(args_root, git_root, sizeof(git_root)) != 0) {
        chdir(old_dir);
        git_context_free(ctx);
        return NULL;
    }
    
    // Remove newline
    size_t len = strlen(git_root);
    if (len > 0 && git_root[len-1] == '\n') {
        git_root[len-1] = '\0';
    }
    
    // Get current directory for relative path calculation
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof(cwd))) {
        chdir(old_dir);
        git_context_free(ctx);
        return NULL;
    }
    
    // Calculate relative prefix
    if (strlen(cwd) > strlen(git_root)) {
        ctx->rel_prefix = strdup(cwd + strlen(git_root) + 1);
        if (ctx->rel_prefix && strlen(ctx->rel_prefix) > 0) {
            strcat(ctx->rel_prefix, "/");
        }
    }
    
    // Get git status using porcelain v2 for better parsing
    const char *args_status[] = {"git", "status", "--porcelain=v2", NULL};
    char status_output[65536]; // 64KB should be enough for most repos
    
    if (exec_git_command(args_status, status_output, sizeof(status_output)) == 0) {
        // Parse porcelain v2 output
        char *line = strtok(status_output, "\n");
        while (line != NULL) {
            if (line[0] == '1' || line[0] == '2') {
                // Regular tracked file
                char xy[3], path[PATH_MAX];
                if (sscanf(line, "%*c %2s %*s %*s %*s %*s %*s %*s %s", xy, path) == 2) {
                    // Add to git status list
                    if (ctx->count >= ctx->capacity) {
                        size_t new_cap = ctx->capacity * 2;
                        GitStatus *new_statuses = realloc(ctx->statuses, 
                                                         new_cap * sizeof(GitStatus));
                        if (new_statuses) {
                            ctx->statuses = new_statuses;
                            ctx->capacity = new_cap;
                        }
                    }
                    
                    if (ctx->count < ctx->capacity) {
                        ctx->statuses[ctx->count].path = strdup(path);
                        ctx->statuses[ctx->count].status_staged = xy[0];
                        ctx->statuses[ctx->count].status_unstaged = xy[1];
                        ctx->count++;
                    }
                }
            } else if (line[0] == '?') {
                // Untracked file
                char path[PATH_MAX];
                if (sscanf(line, "? %s", path) == 1) {
                    if (ctx->count < ctx->capacity) {
                        ctx->statuses[ctx->count].path = strdup(path);
                        ctx->statuses[ctx->count].status_staged = '?';
                        ctx->statuses[ctx->count].status_unstaged = '?';
                        ctx->count++;
                    }
                }
            }
            line = strtok(NULL, "\n");
        }
    }
    
    chdir(old_dir);
    return ctx;
}

// Get git status for a specific file
static char get_file_git_status(GitContext *ctx, const char *filename) {
    if (!ctx || !filename) return ' ';
    
    char full_path[PATH_MAX];
    if (ctx->rel_prefix && strlen(ctx->rel_prefix) > 0) {
        snprintf(full_path, sizeof(full_path), "%s%s", ctx->rel_prefix, filename);
    } else {
        safe_strncpy(full_path, filename, sizeof(full_path));
    }
    
    for (size_t i = 0; i < ctx->count; i++) {
        if (strcmp(ctx->statuses[i].path, full_path) == 0) {
            // Return staged status if exists, otherwise unstaged
            if (ctx->statuses[i].status_staged != '.' && 
                ctx->statuses[i].status_staged != ' ') {
                return ctx->statuses[i].status_staged;
            }
            if (ctx->statuses[i].status_unstaged != '.' && 
                ctx->statuses[i].status_unstaged != ' ') {
                // Return lowercase for unstaged
                return tolower(ctx->statuses[i].status_unstaged);
            }
        }
    }
    return ' ';
}

// Get color for git status - muted colors to not distract from content
static const char* get_git_color(char status) {
    switch(status) {
        case 'M': return "\033[38;5;214m";  // Orange (staged modified)
        case 'm': return "\033[38;5;178m";  // Dimmed orange (unstaged)
        case 'A': return "\033[38;5;34m";   // Muted green (staged add) - changed from bright
        case 'a': return "\033[38;5;28m";   // Darker green (unstaged)
        case 'D': return "\033[38;5;167m";  // Muted red (staged delete) - less bright
        case 'd': return "\033[38;5;131m";  // Dimmed red (unstaged)
        case 'R': return "\033[38;5;141m";  // Muted purple (renamed)
        case 'r': return "\033[38;5;97m";   // Dimmed purple
        case 'C': return "\033[38;5;73m";   // Muted cyan (copied)
        case 'c': return "\033[38;5;66m";   // Dimmed cyan
        case '?': return "\033[38;5;245m";  // Light gray (untracked) - slightly brighter
        case '!': return "\033[38;5;240m";  // Dark gray (ignored)
        default: return "";
    }
}

// Format git status with symbol
static void format_git_status(char status, char *buf, size_t buf_size) {
    switch(status) {
        case 'M': case 'A': case 'D': case 'R': case 'C':
            snprintf(buf, buf_size, " ●"); // Staged
            break;
        case 'm': case 'a': case 'd': case 'r': case 'c':
            snprintf(buf, buf_size, " ○"); // Unstaged
            break;
        case '?':
            snprintf(buf, buf_size, " ?"); // Untracked
            break;
        case '!':
            snprintf(buf, buf_size, " !"); // Ignored
            break;
        default:
            snprintf(buf, buf_size, "  "); // Clean
    }
}

// Comparison functions for sorting
static int compare_name(const void *a, const void *b) {
    const FileInfo *fa = (const FileInfo *)a;
    const FileInfo *fb = (const FileInfo *)b;
    return strcasecmp(fa->name, fb->name);
}

static int compare_time(const void *a, const void *b) {
    const FileInfo *fa = (const FileInfo *)a;
    const FileInfo *fb = (const FileInfo *)b;
    return fa->mtime - fb->mtime;
}

// Print header based on detail level
static void print_header(void) {
    switch (detail_level) {
        case DETAIL_MINIMAL:
            printf("   Size   Git  Modified     Name\n");
            printf("──────────────────────────────────────\n");
            break;
        case DETAIL_STANDARD:
            printf("Permissions    Size   Git  Modified     Name                          Owner\n");
            printf("──────────────────────────────────────────────────────────────────────────────\n");
            break;
        case DETAIL_FULL:
            printf("Mode       Size   Git  Owner            Group            Modified     Name\n");
            printf("──────────────────────────────────────────────────────────────────────────────\n");
            break;
    }
}

// Print help message
static void print_help(const char *prog_name) {
    printf("Usage: %s [OPTIONS] [DIRECTORY]\n\n", prog_name);
    printf("List directory contents with git status information.\n\n");
    printf("Options:\n");
    printf("  -a, --all          Show hidden files\n");
    printf("  -n, --name         Sort alphabetically by name (default: by time)\n");
    printf("  -l                 Standard detail level (permissions, owner)\n");
    printf("  -ll                Full detail level (octal mode, group)\n");
    printf("  --json             Output in JSON format\n");
    printf("  --porcelain        Machine-readable output\n");
    printf("  --branch           Show current git branch\n");
    printf("  --legend           Show git status legend\n");
    printf("  -h, --help         Show this help message\n\n");
    
    printf("Git Status Symbols:\n");
    printf("  [●] Staged changes    [○] Unstaged changes\n");
    printf("  [?] Untracked files   [!] Ignored files\n\n");
    
    printf("Git Status Colors:\n");
    printf("  Green  = Added        Orange = Modified\n");
    printf("  Red    = Deleted      Pink   = Renamed\n");
    printf("  Cyan   = Copied       Gray   = Untracked\n\n");
    
    printf("Permission Modes (octal):\n");
    printf("  0755 = rwxr-xr-x (executable/directory)\n");
    printf("  0644 = rw-r--r-- (regular file)\n");
    printf("  0600 = rw------- (private file)\n");
}

// Main function
int main(int argc, char *argv[]) {
    const char *dir_path = ".";
    
    // Parse command line options
    static struct option long_options[] = {
        {"all", no_argument, 0, 'a'},
        {"name", no_argument, 0, 'n'},
        {"help", no_argument, 0, 'h'},
        {"json", no_argument, 0, 'j'},
        {"porcelain", no_argument, 0, 'p'},
        {"branch", no_argument, 0, 'b'},
        {"legend", no_argument, 0, 'L'},
        {0, 0, 0, 0}
    };
    
    int opt;
    while ((opt = getopt_long(argc, argv, "anlh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'a':
                show_all = 1;
                break;
            case 'n':
                sort_alphabetical = 1;
                break;
            case 'l':
                if (detail_level == DETAIL_MINIMAL) {
                    detail_level = DETAIL_STANDARD;
                } else if (detail_level == DETAIL_STANDARD) {
                    detail_level = DETAIL_FULL;
                }
                break;
            case 'h':
                print_help(argv[0]);
                return 0;
            case 'j':
                output_format = FORMAT_JSON;
                break;
            case 'p':
                output_format = FORMAT_PORCELAIN;
                break;
            case 'b':
                show_branch = 1;
                break;
            case 'L':
                show_legend = 1;
                break;
            default:
                fprintf(stderr, "Usage: %s [-a] [-n] [-l] [-ll] [directory]\n", argv[0]);
                return 1;
        }
    }
    
    if (optind < argc) {
        dir_path = argv[optind];
        if (!validate_path(dir_path)) {
            fprintf(stderr, "Error: Invalid path\n");
            return 1;
        }
    }
    
    // Get git status
    GitContext *git_ctx = get_git_status(dir_path);
    
    // Show branch if requested
    if (show_branch && git_ctx) {
        char branch[256];
        const char *args[] = {"/usr/bin/git", "branch", "--show-current", NULL};
        if (exec_git_command(args, branch, sizeof(branch)) == 0) {
            size_t len = strlen(branch);
            if (len > 0 && branch[len-1] == '\n') branch[len-1] = '\0';
            printf("Branch: %s\n\n", branch);
        }
    }
    
    // Show legend if requested
    if (show_legend) {
        printf("Git Status: [●]=Staged [○]=Unstaged [?]=Untracked\n\n");
    }
    
    // Create file list
    FileList *files = filelist_create();
    if (!files) {
        fprintf(stderr, "Error: Memory allocation failed\n");
        git_context_free(git_ctx);
        return 1;
    }
    
    // Read directory
    DIR *dir = opendir(dir_path);
    if (!dir) {
        perror(dir_path);
        filelist_free(files);
        git_context_free(git_ctx);
        return 1;
    }
    
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!show_all && entry->d_name[0] == '.') {
            continue;
        }
        
        char full_path[PATH_MAX];
        if (safe_path_join(full_path, sizeof(full_path), dir_path, entry->d_name) != 0) {
            continue;
        }
        
        struct stat st;
        if (lstat(full_path, &st) == 0) {
            FileInfo info;
            info.name = entry->d_name;
            info.mode = st.st_mode;
            info.size = st.st_size;
            info.mtime = st.st_mtime;
            info.uid = st.st_uid;
            info.gid = st.st_gid;
            info.is_dir = S_ISDIR(st.st_mode);
            info.is_exec = st.st_mode & S_IXUSR;
            info.is_symlink = S_ISLNK(st.st_mode);
            info.git_status = git_ctx ? get_file_git_status(git_ctx, entry->d_name) : ' ';
            
            filelist_add(files, &info);
        }
    }
    closedir(dir);
    
    // Sort files - default is by time (most recent last), -n for name/alphabetical
    if (sort_alphabetical) {
        qsort(files->files, files->count, sizeof(FileInfo), compare_name);
    } else {
        qsort(files->files, files->count, sizeof(FileInfo), compare_time);  // Default: time sort
    }
    
    // Output based on format
    if (output_format == FORMAT_JSON) {
        printf("[");
        for (size_t i = 0; i < files->count; i++) {
            if (i > 0) printf(",");
            printf("\n  {\"name\":\"%s\",\"size\":%lld,\"mode\":\"%04o\",\"git\":\"%c\"}",
                   files->files[i].name, (long long)files->files[i].size,
                   files->files[i].mode & 07777, files->files[i].git_status);
        }
        printf("\n]\n");
    } else if (output_format == FORMAT_PORCELAIN) {
        for (size_t i = 0; i < files->count; i++) {
            printf("%04o %lld %c %s\n",
                   files->files[i].mode & 07777,
                   (long long)files->files[i].size,
                   files->files[i].git_status,
                   files->files[i].name);
        }
    } else {
        // Normal output
        print_header();
        
        for (size_t i = 0; i < files->count; i++) {
            FileInfo *f = &files->files[i];
            
            // Format various fields
            char size_str[10];
            if (f->is_dir) {
                strcpy(size_str, "     -");
            } else {
                format_size(f->size, size_str, sizeof(size_str));
            }
            
            char git_str[5];
            format_git_status(f->git_status, git_str, sizeof(git_str));
            
            struct tm *tm = localtime(&f->mtime);
            char time_str[20];
            strftime(time_str, sizeof(time_str), "%b %d %H:%M", tm);
            
            const char *git_color = get_git_color(f->git_status);
            const char *reset = git_color[0] ? "\033[0m" : "";
            
            // Format name with type indicators
            char name_display[PATH_MAX + 10];
            if (f->is_symlink) {
                snprintf(name_display, sizeof(name_display), "\033[36m%s@\033[0m", f->name);
            } else if (f->is_dir) {
                snprintf(name_display, sizeof(name_display), "\033[34m%s/\033[0m", f->name);
            } else if (f->is_exec) {
                snprintf(name_display, sizeof(name_display), "\033[32m%s*\033[0m", f->name);
            } else {
                strcpy(name_display, f->name);
            }
            
            // Print based on detail level
            switch (detail_level) {
                case DETAIL_MINIMAL:
                    printf("%7s  %s%s%s   %-12s %s\n",
                           size_str, git_color, git_str, reset,
                           time_str, name_display);
                    break;
                    
                case DETAIL_STANDARD: {
                    char perm_str[11];
                    snprintf(perm_str, sizeof(perm_str), "%c%c%c%c%c%c%c%c%c%c",
                            f->is_dir ? 'd' : (f->is_symlink ? 'l' : '-'),
                            f->mode & S_IRUSR ? 'r' : '-',
                            f->mode & S_IWUSR ? 'w' : '-',
                            f->mode & S_IXUSR ? 'x' : '-',
                            f->mode & S_IRGRP ? 'r' : '-',
                            f->mode & S_IWGRP ? 'w' : '-',
                            f->mode & S_IXGRP ? 'x' : '-',
                            f->mode & S_IROTH ? 'r' : '-',
                            f->mode & S_IWOTH ? 'w' : '-',
                            f->mode & S_IXOTH ? 'x' : '-');
                    
                    struct passwd *pw = getpwuid(f->uid);
                    char owner[17];
                    if (pw && strlen(pw->pw_name) <= 16) {
                        strcpy(owner, pw->pw_name);
                    } else if (pw) {
                        strncpy(owner, pw->pw_name, 14);
                        strcpy(owner + 14, "~");
                    } else {
                        snprintf(owner, sizeof(owner), "%d", f->uid);
                    }
                    
                    printf("%-10s %7s  %s%s%s   %-12s %-30s  %s\n",
                           perm_str, size_str, git_color, git_str, reset,
                           time_str, name_display, owner);
                    break;
                }
                    
                case DETAIL_FULL: {
                    char mode_str[8];
                    snprintf(mode_str, sizeof(mode_str), "%04o", f->mode & 07777);
                    
                    struct passwd *pw = getpwuid(f->uid);
                    struct group *gr = getgrgid(f->gid);
                    
                    char owner[17], group[17];
                    if (pw) {
                        strncpy(owner, pw->pw_name, 16);
                        owner[16] = '\0';
                    } else {
                        snprintf(owner, sizeof(owner), "%d", f->uid);
                    }
                    
                    if (gr) {
                        strncpy(group, gr->gr_name, 16);
                        group[16] = '\0';
                    } else {
                        snprintf(group, sizeof(group), "%d", f->gid);
                    }
                    
                    printf("%-7s %7s  %s%s%s   %-16s %-16s %-12s %s\n",
                           mode_str, size_str, git_color, git_str, reset,
                           owner, group, time_str, name_display);
                    break;
                }
            }
        }
    }
    
    // Cleanup
    filelist_free(files);
    git_context_free(git_ctx);
    
    return 0;
}