#include "jb_log.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>

#define LOG_PATH_FILE "/var/mobile/dopamine-log-path"
#define FALLBACK_LOG "/var/mobile/dopamine-launchd.log"

static void jb_log_write_path(const char *path, const char *line)
{
	if (!path || !path[0] || !line) return;
	int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
	if (fd < 0) return;
	write(fd, line, strlen(line));
	fsync(fd);
	close(fd);
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

	jb_log_write_path(FALLBACK_LOG, line);

	char extra[512];
	extra[0] = 0;
	int pfd = open(LOG_PATH_FILE, O_RDONLY);
	if (pfd >= 0) {
		ssize_t n = read(pfd, extra, sizeof(extra) - 1);
		close(pfd);
		if (n > 0) {
			extra[n] = 0;
			char *nl = strchr(extra, '\n');
			if (nl) *nl = 0;
			jb_log_write_path(extra, line);
		}
	}
}
