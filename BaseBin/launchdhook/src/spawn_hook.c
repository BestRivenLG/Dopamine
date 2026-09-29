#include <spawn.h>
#include "../systemhook/src/common/common.h"
#include "../systemhook/src/common/envbuf.h"
#include "boomerang.h"
#include "crashreporter.h"
#include "update.h"
#include <libjailbreak/util.h>
#include <substrate.h>
#include <mach-o/dyld.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <litehook.h>
#include "jbserver/jbserver_local.h"
#include "hookd_provider.h"
#include "jb_log.h"
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
extern char **environ;

void abort_with_reason(uint32_t reason_namespace, uint64_t reason_code, const char *reason_string, uint64_t reason_flags);

extern int systemwide_trust_file_by_path(const char *path);
extern int platform_set_process_debugged(uint64_t pid, bool fullyDebugged);
extern void systemwide_domain_set_enabled(bool enabled);

#define LOG_PROCESS_LAUNCHES 0

extern bool gInEarlyBoot;
extern bool gFreeBootLogoBeforeBackboardd;
void free_boot_logo(void);

void early_boot_done(void)
{
	__atomic_store_n(&gInEarlyBoot, false, __ATOMIC_RELEASE);
}

void ensure_fakelib_mounted(void)
{
	struct statfs fsb;
	if (statfs("/usr/lib", &fsb) != 0) return;
	if (strcmp(fsb.f_mntonname, "/usr/lib") != 0) {
		systemwide_domain_set_enabled(true);

		// The jailbreak server is not reachable at this point in the launchd lifecycle
		// So we need to host our own, just so that jbctl can talk to it
		mach_port_t serverPort = jbserver_local_start();
		jbctl_earlyboot(serverPort, "internal", "fakelib", "mount", NULL);
		jbserver_local_stop();

		// Note down that the jailbreak was hidden
		// So that after the userspace reboot, we can unmount fakelib again
		setenv("DOPAMINE_IS_HIDDEN", "1", true);
	}
}

int __posix_spawn_orig_wrapper(pid_t *restrict pid, const char *restrict path,
					   struct _posix_spawn_args_desc *desc,
					   char *const argv[restrict],
					   char *const envp[restrict])
{
	// we need to disable the crash reporter during the orig call
	// otherwise the child process inherits the exception ports
	// and this would trip jailbreak detections
	crashreporter_pause();	
	int r = __posix_spawn_inline(pid, path, desc, argv, envp);
	crashreporter_resume();

	return r;
}

static bool is_launchd_userspace_reboot_spawn(const char *path)
{
	if (!path || getpid() != 1) return false;

	char executablePath[1024];
	uint32_t bufsize = sizeof(executablePath);
	if (_NSGetExecutablePath(executablePath, &bufsize) != 0) return false;
	if (!strcmp(path, executablePath)) return true;

	const char *base1 = strrchr(path, '/');
	const char *base2 = strrchr(executablePath, '/');
	base1 = base1 ? base1 + 1 : path;
	base2 = base2 ? base2 + 1 : executablePath;
	if (strcmp(base1, "launchd") != 0 || strcmp(base2, "launchd") != 0) return false;

	char resolved1[PATH_MAX] = {0};
	char resolved2[PATH_MAX] = {0};
	if (realpath(path, resolved1) && realpath(executablePath, resolved2) && !strcmp(resolved1, resolved2)) {
		return true;
	}
	return false;
}

int __posix_spawn_hook(pid_t *restrict pid, const char *restrict path,
					   struct _posix_spawn_args_desc *desc,
					   char *const argv[restrict],
					   char *const envp[restrict])
{
	if (path && getpid() == 1 && strstr(path, "launchd")) {
		char executablePath[1024];
		uint32_t bufsize = sizeof(executablePath);
		_NSGetExecutablePath(executablePath, &bufsize);
		jb_log("posix_spawn path=%s self=%s match=%d", path, executablePath, is_launchd_userspace_reboot_spawn(path));
	}
	if (path) {
		char executablePath[1024];
		uint32_t bufsize = sizeof(executablePath);
		_NSGetExecutablePath(&executablePath[0], &bufsize);
		if (is_launchd_userspace_reboot_spawn(path)) {
			jb_log("USERSPACE REBOOT spawn path=%s self=%s", path, executablePath);
			// This spawn will perform a userspace reboot...
			// Instead of the ordinary hook, we want to reinsert this dylib
			// This has already been done in envp so we only need to call the original posix_spawn

			// We are back in "early boot" for the remainder of this launchd instance
			// Mainly so we don't lock up while spawning boomerang
			__atomic_store_n(&gInEarlyBoot, true, __ATOMIC_RELEASE);

			hookd_provider_teardown();

			// If the jailbreak is currently hidden, fakelib is not mounted
			// It needs to be mounted to regain launchd code execution after the userspace reboot
			ensure_fakelib_mounted();

#if LOG_PROCESS_LAUNCHES
			FILE *f = fopen("/var/mobile/launch_log.txt", "a");
			fprintf(f, "==== USERSPACE REBOOT ====\n");
			fclose(f);
#endif

			// Before the userspace reboot, we want to stash the primitives into boomerang
			jb_log("boomerang_stashPrimitives begin");
			boomerang_stashPrimitives();
			jb_log("boomerang_stashPrimitives done insert=%s", getenv("DYLD_INSERT_LIBRARIES") ?: "(null)");

			// Fix Xcode debugging being broken after the userspace reboot
			if (__builtin_available(iOS 17.0, *)) {
				unmount("/System/Developer", MNT_FORCE);
			}
			else {
				unmount("/Developer", MNT_FORCE);
			}

			// If there is a pending jailbreak update, apply it now
			const char *stagedJailbreakUpdate = getenv("STAGED_JAILBREAK_UPDATE");
			if (stagedJailbreakUpdate) {
				int r = jbupdate_basebin(stagedJailbreakUpdate);
				if (r != 0) {
					char msg[1000];
					snprintf(msg, 1000, "Failed updating basebin (error %d).", r);
					abort_with_reason(7, 1, msg, 0);
				}
				unsetenv("STAGED_JAILBREAK_UPDATE");
			}

			// Always use environ instead of envp, as boomerang_stashPrimitives calls setenv
			// setenv / unsetenv can sometimes cause environ to get reallocated
			// In that case envp may point to garbage or be empty
			// Say goodbye to this process
			jb_log("calling orig posix_spawn for new launchd");
			int r = __posix_spawn_orig_wrapper(pid, path, desc, argv, environ);
			jb_log("orig posix_spawn returned %d", r);
			return r;
		}
	}

#if LOG_PROCESS_LAUNCHES
	if (path) {
		FILE *f = fopen("/var/mobile/launch_log.txt", "a");
		fprintf(f, "%s", path);
		int ai = 0;
		while (argv) {
			if (argv[ai]) {
				if (ai >= 1) {
					fprintf(f, " %s", argv[ai]);
				}
				ai++;
			}
			else {
				break;
			}
		}
		fprintf(f, "\n");
		fclose(f);

		// if (!strcmp(path, "/usr/libexec/xpcproxy")) {
		// 	const char *tmpBlacklist[] = {
		// 		"com.apple.logd"
		// 	};
		// 	size_t blacklistCount = sizeof(tmpBlacklist) / sizeof(tmpBlacklist[0]);
		// 	for (size_t i = 0; i < blacklistCount; i++)
		// 	{
		// 		if (!strcmp(tmpBlacklist[i], firstArg)) {
		// 			FILE *f = fopen("/var/mobile/launch_log.txt", "a");
		// 			fprintf(f, "blocked injection %s\n", firstArg);
		// 			fclose(f);
		// 			return __posix_spawn_orig_wrapper(pid, path, file_actions, desc, envp);
		// 		}
		// 	}
		// }
	}
#endif

	// The first xpcproxy spawn can precede launchd's XPC server readiness.
	// Keep early spawns free of jailbreak injection until an XPC message arrives.
	if (__atomic_load_n(&gInEarlyBoot, __ATOMIC_ACQUIRE)) {
		bool isXpcproxy = path && !strcmp(path, "/usr/libexec/xpcproxy");
		char **cleanEnv = NULL;
		char *const *spawnEnv = envp;
		if (isXpcproxy) {
			jb_log("early xpcproxy service=%s insert=%s", argv && argv[1] ? argv[1] : "(null)", envbuf_getenv((const char **)envp, "DYLD_INSERT_LIBRARIES") ?: "(null)");
			cleanEnv = envbuf_mutcopy((const char **)envp);
			if (envp && !cleanEnv) return ENOMEM;
			if (cleanEnv) {
				envbuf_unsetenv(&cleanEnv, "DYLD_INSERT_LIBRARIES");
				spawnEnv = cleanEnv;
			}
		}
		int r = __posix_spawn_orig_wrapper(pid, path, desc, argv, spawnEnv);
		envbuf_free(cleanEnv);
		if (path && strstr(path, "launchd")) {
			jb_log("early posix_spawn path=%s ret=%d pid=%d", path, r, pid ? *pid : -1);
		}
		if (isXpcproxy) {
			jb_log("early xpcproxy ret=%d pid=%d", r, pid ? *pid : -1);
		}
		return r;
	}

	// If we're drawing a boot logo, free up it's resources before backboardd starts
	if (gFreeBootLogoBeforeBackboardd) {
		if (!strcmp(path, "/usr/libexec/xpcproxy")) {
			if (argv[0]) {
				if (argv[1]) {
					if (!strcmp(argv[1], "com.apple.backboardd\n")) {
						free_boot_logo();
						gFreeBootLogoBeforeBackboardd = false;
					}
				}
			}
		}
	}

	bool isXpcproxy = path && !strcmp(path, "/usr/libexec/xpcproxy");
	static unsigned xpcproxyLogCount = 0;
	unsigned xpcproxyIndex = isXpcproxy ? __sync_fetch_and_add(&xpcproxyLogCount, 1) : 0;
	bool logXpcproxy = isXpcproxy && xpcproxyIndex < 64;
	if (logXpcproxy && xpcproxyIndex < 16) jb_log("xpcproxy spawn begin service=%s", argv && argv[1] ? argv[1] : "(null)");
	int r = posix_spawn_hook_shared(pid, path, desc, argv, envp, __posix_spawn_orig_wrapper, systemwide_trust_file_by_path, platform_set_process_debugged, jbsetting(jetsamMultiplier));
	if (logXpcproxy) jb_log("xpcproxy spawn end service=%s ret=%d pid=%d", argv && argv[1] ? argv[1] : "(null)", r, pid ? *pid : -1);
	return r;
}

void initSpawnHooks(void)
{
	litehook_hook_function(__posix_spawn, __posix_spawn_hook);
}
