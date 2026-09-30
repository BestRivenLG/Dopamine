#include "jb_log.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <errno.h>

#define LOG_PATH_FILE "/var/mobile/dopamine-log-path"
#define FALLBACK_LOG "/var/mobile/dopamine-launchd.log"

static bool jb_log_write_path(const char *path, const char *line)
{
	if (!path || !path[0] || !line) return false;
	int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
	if (fd < 0) return false;
	size_t length = strlen(line);
	size_t offset = 0;
	while (offset < length) {
		ssize_t written = write(fd, line + offset, length - offset);
		if (written < 0 && errno == EINTR) continue;
		if (written <= 0) break;
		offset += (size_t)written;
	}
	close(fd);
	return offset == length;
}

static const char *jb_log_path(void)
{
	static char path[512];
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		int fd = open(LOG_PATH_FILE, O_RDONLY);
		if (fd >= 0) {
			ssize_t n = read(fd, path, sizeof(path) - 1);
			close(fd);
			if (n > 0) {
				path[n] = 0;
				char *nl = strchr(path, '\n');
				if (nl) *nl = 0;
			}
		}
		if (!path[0]) strlcpy(path, FALLBACK_LOG, sizeof(path));
	});
	return path;
}

void jb_log(const char *fmt, ...)
{
	char body[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(body, sizeof(body), fmt, ap);
	va_end(ap);

	struct timeval tv;
	gettimeofday(&tv, NULL);
	struct tm tm;
	localtime_r(&tv.tv_sec, &tm);
	char line[1200];
	snprintf(line, sizeof(line), "[launchd %02d:%02d:%02d] %s\n", tm.tm_hour, tm.tm_min, tm.tm_sec, body);

	const char *path = jb_log_path();
	if (!jb_log_write_path(path, line) && strcmp(path, FALLBACK_LOG) != 0) {
		jb_log_write_path(FALLBACK_LOG, line);
	}
}
