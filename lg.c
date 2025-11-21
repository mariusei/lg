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

#define MAX_PATH 4096
#define MAX_FILES 10000

typedef struct {
    char name[256];
    mode_t mode;
    off_t size;
    time_t mtime;
    uid_t uid;
    gid_t gid;
    char git_status;
    int is_dir;
    int is_exec;
} FileInfo;

typedef struct {
    char path[MAX_PATH];
    char status;
} GitStatus;

GitStatus git_statuses[MAX_FILES];
int git_status_count = 0;

void format_size(off_t size, char *buf) {
    if (size < 1024) {
        sprintf(buf, "%4lldB", (long long)size);
    } else if (size < 1024 * 1024) {
        sprintf(buf, "%4.1fK", size / 1024.0);
    } else if (size < 1024 * 1024 * 1024) {
        sprintf(buf, "%4.1fM", size / (1024.0 * 1024));
    } else {
        sprintf(buf, "%4.1fG", size / (1024.0 * 1024 * 1024));
    }
}

void get_git_status() {
    FILE *fp;
    char line[MAX_PATH + 10];
    char status[3];
    char path[MAX_PATH];
    
    // Check if we're in a git repo
    fp = popen("git rev-parse --git-dir 2>/dev/null", "r");
    if (!fp) return;
    if (!fgets(line, sizeof(line), fp)) {
        pclose(fp);
        return;
    }
    pclose(fp);
    
    // Get staged files
    fp = popen("git diff --name-status --cached 2>/dev/null", "r");
    if (fp) {
        while (fgets(line, sizeof(line), fp)) {
            if (sscanf(line, "%2s\t%s", status, path) == 2) {
                if (git_status_count < MAX_FILES) {
                    strcpy(git_statuses[git_status_count].path, path);
                    git_statuses[git_status_count].status = status[0];
                    git_status_count++;
                }
            }
        }
        pclose(fp);
    }
    
    // Get unstaged files
    fp = popen("git diff --name-status 2>/dev/null", "r");
    if (fp) {
        while (fgets(line, sizeof(line), fp)) {
            if (sscanf(line, "%2s\t%s", status, path) == 2) {
                int found = 0;
                for (int i = 0; i < git_status_count; i++) {
                    if (strcmp(git_statuses[i].path, path) == 0) {
                        found = 1;
                        break;
                    }
                }
                if (!found && git_status_count < MAX_FILES) {
                    strcpy(git_statuses[git_status_count].path, path);
                    git_statuses[git_status_count].status = status[0] + 32; // lowercase
                    git_status_count++;
                }
            }
        }
        pclose(fp);
    }
    
    // Get untracked files
    fp = popen("git ls-files --others --exclude-standard 2>/dev/null", "r");
    if (fp) {
        while (fgets(line, sizeof(line), fp)) {
            line[strcspn(line, "\n")] = 0;
            if (strlen(line) > 0) {
                int found = 0;
                for (int i = 0; i < git_status_count; i++) {
                    if (strcmp(git_statuses[i].path, line) == 0) {
                        found = 1;
                        break;
                    }
                }
                if (!found && git_status_count < MAX_FILES) {
                    strcpy(git_statuses[git_status_count].path, line);
                    git_statuses[git_status_count].status = '?';
                    git_status_count++;
                }
            }
        }
        pclose(fp);
    }
}

char get_file_git_status(const char *path) {
    for (int i = 0; i < git_status_count; i++) {
        if (strcmp(git_statuses[i].path, path) == 0) {
            return git_statuses[i].status;
        }
    }
    return ' ';
}

const char* get_git_color(char status) {
    switch(status) {
        case 'M': case 'm': return "\033[33m";  // Yellow
        case 'A': case 'a': return "\033[32m";  // Green
        case 'D': case 'd': return "\033[31m";  // Red
        case 'R': case 'r': return "\033[35m";  // Magenta
        case 'C': case 'c': return "\033[36m";  // Cyan
        case '?': return "\033[90m";            // Gray
        case '!': return "\033[90m";            // Gray
        default: return "";
    }
}

int compare_name(const void *a, const void *b) {
    FileInfo *fa = (FileInfo *)a;
    FileInfo *fb = (FileInfo *)b;
    return strcasecmp(fa->name, fb->name);
}

int compare_time(const void *a, const void *b) {
    FileInfo *fa = (FileInfo *)a;
    FileInfo *fb = (FileInfo *)b;
    return fa->mtime - fb->mtime;
}

int main(int argc, char *argv[]) {
    DIR *dir;
    struct dirent *entry;
    struct stat st;
    FileInfo files[MAX_FILES];
    int file_count = 0;
    int show_all = 0;
    int sort_by_time = 0;
    char *dir_path = ".";
    int opt;
    
    // Parse arguments
    while ((opt = getopt(argc, argv, "at")) != -1) {
        switch (opt) {
            case 'a':
                show_all = 1;
                break;
            case 't':
                sort_by_time = 1;
                break;
            default:
                fprintf(stderr, "Usage: %s [-a] [-t] [directory]\n", argv[0]);
                exit(1);
        }
    }
    
    if (optind < argc) {
        dir_path = argv[optind];
    }
    
    // Get git status
    get_git_status();
    
    // Open directory
    dir = opendir(dir_path);
    if (!dir) {
        perror(dir_path);
        return 1;
    }
    
    // Read directory entries
    while ((entry = readdir(dir)) != NULL) {
        if (!show_all && entry->d_name[0] == '.') {
            continue;
        }
        
        char full_path[MAX_PATH];
        snprintf(full_path, sizeof(full_path), "%s/%s", dir_path, entry->d_name);
        
        if (stat(full_path, &st) == 0 && file_count < MAX_FILES) {
            strcpy(files[file_count].name, entry->d_name);
            files[file_count].mode = st.st_mode;
            files[file_count].size = st.st_size;
            files[file_count].mtime = st.st_mtime;
            files[file_count].uid = st.st_uid;
            files[file_count].gid = st.st_gid;
            files[file_count].is_dir = S_ISDIR(st.st_mode);
            files[file_count].is_exec = st.st_mode & S_IXUSR;
            
            // Get relative path for git status
            char rel_path[MAX_PATH];
            if (strcmp(dir_path, ".") == 0) {
                strcpy(rel_path, entry->d_name);
            } else {
                snprintf(rel_path, sizeof(rel_path), "%s/%s", dir_path, entry->d_name);
            }
            files[file_count].git_status = get_file_git_status(rel_path);
            
            file_count++;
        }
    }
    closedir(dir);
    
    // Sort files
    if (sort_by_time) {
        qsort(files, file_count, sizeof(FileInfo), compare_time);
    } else {
        qsort(files, file_count, sizeof(FileInfo), compare_name);
    }
    
    // Print header
    printf("%-7s %5s %-3s %-8s %-8s %-12s Name\n", "Mode", "Size", "Git", "Owner", "Group", "Modified");
    printf("----------------------------------------------------------------------\n");
    
    // Print files
    for (int i = 0; i < file_count; i++) {
        // Format mode as octal
        char mode_str[8];
        sprintf(mode_str, "0%o", files[i].mode & 07777);
        
        // Format size
        char size_str[10];
        if (files[i].is_dir) {
            strcpy(size_str, "    -");
        } else {
            format_size(files[i].size, size_str);
        }
        
        // Get owner and group names
        struct passwd *pw = getpwuid(files[i].uid);
        struct group *gr = getgrgid(files[i].gid);
        char *owner = pw ? pw->pw_name : "?";
        char *group = gr ? gr->gr_name : "?";
        
        // Format time
        struct tm *tm = localtime(&files[i].mtime);
        char time_str[20];
        strftime(time_str, sizeof(time_str), "%b %d %H:%M", tm);
        
        // Get git status color
        const char *git_color = get_git_color(files[i].git_status);
        const char *reset = git_color[0] ? "\033[0m" : "";
        
        // Format name with color
        if (files[i].is_dir) {
            printf("%-7s %5s %s%c%s   %-8s %-8s %-12s \033[34m%s/\033[0m\n",
                   mode_str, size_str, git_color, files[i].git_status, reset,
                   owner, group, time_str, files[i].name);
        } else if (files[i].is_exec) {
            printf("%-7s %5s %s%c%s   %-8s %-8s %-12s \033[32m%s\033[0m\n",
                   mode_str, size_str, git_color, files[i].git_status, reset,
                   owner, group, time_str, files[i].name);
        } else {
            printf("%-7s %5s %s%c%s   %-8s %-8s %-12s %s\n",
                   mode_str, size_str, git_color, files[i].git_status, reset,
                   owner, group, time_str, files[i].name);
        }
    }
    
    return 0;
}