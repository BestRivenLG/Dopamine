//
//  DOUIManager.m
//  Dopamine
//
//  Created by tomt000 on 24/01/2024.
//

#import "DOUIManager.h"
#import "DOEnvironmentManager.h"
#import "DOThemeManager.h"
#import "DOTheme.h"
#import "NSString+Version.h"
#import <pthread.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <sys/stat.h>

@implementation DOUIManager

+ (instancetype)sharedInstance
{
    static DOUIManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[DOUIManager alloc] init];
    });
    return sharedInstance;
}

- (id)init
{
    if (self = [super init]){
        // elevatePrivileges later sets HOME=/var/root; pin Documents now.
        // Prefer the container API so we don't depend on HOME at all.
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _documentsDirectory = docs ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        _bootlogoPath = [_documentsDirectory stringByAppendingPathComponent:@"bootlogo.png"];
        _preferenceManager = [DOPreferenceManager sharedManager];
        _logRecord = [NSMutableArray new];
        _logLock = [NSLock new];
        _logFileFd = -1;
    }
    return self;
}

- (NSString *)jailbreakLogPath
{
    return [_documentsDirectory stringByAppendingPathComponent:@"jailbreak.log"];
}

- (void)writeLogBytes:(const char *)bytes length:(size_t)len
{
    if (!bytes || len == 0) return;

    if (_logFileFd >= 0) {
        // fd was opened as mobile before elevatePrivileges; stays valid after uid 0 / HOME change.
        write(_logFileFd, bytes, len);
        fsync(_logFileFd);
        return;
    }

    const char *path = self.jailbreakLogPath.fileSystemRepresentation;
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    write(fd, bytes, len);
    fsync(fd);
    close(fd);
}

- (void)persistJailbreakLogLine:(NSString *)log
{
    if (log.length == 0) return;
    NSString *line = [log hasSuffix:@"\n"] ? log : [log stringByAppendingString:@"\n"];
    const char *bytes = line.UTF8String;
    if (!bytes) return;
    [self writeLogBytes:bytes length:strlen(bytes)];
}

- (NSString *)lastJailbreakLog
{
    NSString *primary = [NSString stringWithContentsOfFile:[self jailbreakLogPath] encoding:NSUTF8StringEncoding error:nil];

    if (!primary.length) {
        NSString *savedPath = [NSString stringWithContentsOfFile:@"/var/mobile/dopamine-log-path" encoding:NSUTF8StringEncoding error:nil];
        savedPath = [savedPath stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([savedPath hasPrefix:@"/var/mobile/Containers/Data/Application/"] && [savedPath hasSuffix:@"/Documents/jailbreak.log"]) {
            NSString *savedLog = [NSString stringWithContentsOfFile:savedPath encoding:NSUTF8StringEncoding error:nil];
            if (savedLog.length) primary = [NSString stringWithFormat:@"[日志来源：%@]\n%@", savedPath, savedLog];
        }
    }

    if (!primary.length) {
        NSString *previousPath = [_documentsDirectory stringByAppendingPathComponent:@"jailbreak.previous.log"];
        NSString *previousLog = [NSString stringWithContentsOfFile:previousPath encoding:NSUTF8StringEncoding error:nil];
        if (previousLog.length) primary = [NSString stringWithFormat:@"[上一次越狱日志：%@]\n%@", previousPath, previousLog];
    }

    // Fallback if HOME drifted before we pinned Documents.
    if (!primary.length) {
        NSString *homePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jailbreak.log"];
        if (![homePath isEqualToString:[self jailbreakLogPath]]) {
            primary = [NSString stringWithContentsOfFile:homePath encoding:NSUTF8StringEncoding error:nil];
        }
    }

    NSMutableString *combined = [NSMutableString stringWithString:primary ?: @""];
    NSString *launchdPath = @"/var/mobile/dopamine-launchd.log";
    NSString *launchdLog = [NSString stringWithContentsOfFile:launchdPath encoding:NSUTF8StringEncoding error:nil];
    if (launchdLog.length) {
        [combined appendFormat:@"\n\n===== 独立 launchd 日志：%@ =====\n%@", launchdPath, launchdLog];
    }

    NSString *crashDirectory = @"/var/mobile/Library/Logs/CrashReporter";
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *latestCrashPath = nil;
    NSDate *latestCrashDate = nil;
    for (NSString *name in [fileManager contentsOfDirectoryAtPath:crashDirectory error:nil]) {
        if (!([name hasPrefix:@"launchd-"] || [name hasPrefix:@"userspace-panic-"] || [name hasPrefix:@"panic-full-"] || [name hasPrefix:@"watchdog-"]) || ![name hasSuffix:@".ips"]) continue;
        NSString *path = [crashDirectory stringByAppendingPathComponent:name];
        NSDate *modified = [fileManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (modified && [modified timeIntervalSinceNow] > -86400 && (!latestCrashDate || [modified compare:latestCrashDate] == NSOrderedDescending)) {
            latestCrashDate = modified;
            latestCrashPath = path;
        }
    }
    if (latestCrashPath) {
        NSString *crashLog = [NSString stringWithContentsOfFile:latestCrashPath encoding:NSUTF8StringEncoding error:nil];
        if (crashLog.length) [combined appendFormat:@"\n\n===== 故障报告：%@，修改时间 %@ =====\n%@", latestCrashPath, latestCrashDate, crashLog];
    }

    return combined;
}

- (BOOL)isUpdateAvailable
{
    NSString *latestVersion = [self getLatestReleaseTag];
    NSString *currentVersion = [self getLaunchedReleaseTag];
    return [latestVersion numericalVersionRepresentation] > [currentVersion numericalVersionRepresentation];
}

- (NSArray *)getUpdatesInRange:(NSString *)start end:(NSString *)end
{
    NSArray *releases = [self getLatestReleases];
    if (releases.count == 0)
        return @[];

    long long startVersion = [start numericalVersionRepresentation];
    long long endVersion = [end numericalVersionRepresentation];
    NSMutableArray *updates = [NSMutableArray new];
    for (NSDictionary *release in releases) {
        NSString *version = release[@"tag_name"];
        NSNumber *prerelease = release[@"prerelease"];
        if ([prerelease boolValue]) {
            // Skip prereleases
            continue;
        }
        long long numericalVersion = [version numericalVersionRepresentation];
        if (numericalVersion > startVersion && numericalVersion <= endVersion) {
            [updates addObject:release];
        }
    }
    return updates;
}

- (NSArray *)getLatestReleases
{
    static dispatch_once_t onceToken;
    static NSArray *releases;
    dispatch_once(&onceToken, ^{
        NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/opa334/Dopamine/releases"];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data) {
            NSError *error;
            releases = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&error];
            if (error)
            {
                onceToken = 0;
                releases = @[];
            }
        }
    });
    return releases;
}

- (BOOL)environmentUpdateAvailable
{
    if (![[DOEnvironmentManager sharedManager] jailbrokenVersion])
        return NO;

    NSString *jailbrokenVersion = [[DOEnvironmentManager sharedManager] jailbrokenVersion];
    NSString *launchedVersion = [self getLaunchedReleaseTag];
    
    return [launchedVersion numericalVersionRepresentation] > [jailbrokenVersion numericalVersionRepresentation];
}

- (bool)launchedReleaseNeedsManualUpdate
{
    NSString *launchedTag = [self getLaunchedReleaseTag];
    NSDictionary *launchedVersion;
    for (NSDictionary *release in [self getLatestReleases]) {
        if ([release[@"tag_name"] isEqualToString:launchedTag]) {
            launchedVersion = release;
            break;
        }
    }
    if (!launchedVersion)
        return false;
    return [launchedVersion[@"body"] containsString:@"*Manual Updates*"];
}

- (NSString*)getLatestReleaseTag
{
    NSArray *releases = [self getLatestReleases];
    for (NSDictionary *release in releases) {
        NSNumber *prerelease = release[@"prerelease"];
        if ([prerelease boolValue]) {
            continue;
        }
        return release[@"tag_name"];
    }
    return nil;
}

- (NSString*)getLaunchedReleaseTag
{
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

- (NSArray*)availablePackageManagers
{
    NSString *path = [[NSBundle mainBundle] pathForResource:@"PkgManagers" ofType:@"plist"];
    return [NSArray arrayWithContentsOfFile:path];
}

- (NSArray*)enabledPackageManagerKeys
{
    NSArray *enabledPkgManagers = [_preferenceManager preferenceValueForKey:@"enabledPkgManagers"] ?: @[];
    NSMutableArray *enabledKeys = [NSMutableArray new];
    NSArray *availablePkgManagers = [self availablePackageManagers];

    [availablePkgManagers enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *key = obj[@"Key"];
        if ([enabledPkgManagers containsObject:key]) {
            [enabledKeys addObject:key];
        }
    }];

    return enabledKeys;
}

- (NSArray*)enabledPackageManagers
{
    NSMutableArray *enabledPkgManagers = [NSMutableArray new];
    NSArray *enabledKeys = [self enabledPackageManagerKeys];

    [[self availablePackageManagers] enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *key = obj[@"Key"];
        if ([enabledKeys containsObject:key]) {
            [enabledPkgManagers addObject:obj];
        }
    }];

    return enabledPkgManagers;
}

- (void)resetPackageManagers
{
    [_preferenceManager removePreferenceValueForKey:@"enabledPkgManagers"];
}

- (void)resetSettings
{
    [_preferenceManager removePreferenceValueForKey:@"verboseLogsEnabled"];
    [_preferenceManager removePreferenceValueForKey:@"tweakInjectionEnabled"];
    [self resetPackageManagers];
}

- (void)setPackageManager:(NSString*)key enabled:(BOOL)enabled
{
    NSMutableArray *pkgManagers = [self enabledPackageManagerKeys].mutableCopy;
    
    if (enabled && ![pkgManagers containsObject:key]) {
        [pkgManagers addObject:key];
    }
    else if (!enabled && [pkgManagers containsObject:key]) {
        [pkgManagers removeObject:key];
    }

    [_preferenceManager setPreferenceValue:pkgManagers forKey:@"enabledPkgManagers"];
}

- (BOOL)isDebug
{
    NSNumber *debug = [_preferenceManager preferenceValueForKey:@"verboseLogsEnabled"];
    return debug == nil ? NO : [debug boolValue];
}

- (BOOL)enableTweaks
{
    NSNumber *tweaks = [_preferenceManager preferenceValueForKey:@"tweakInjectionEnabled"];
    return tweaks == nil ? YES : [tweaks boolValue];
}

- (void)sendLog:(NSString*)log debug:(BOOL)debug update:(BOOL)update
{
    if (!log)
        return;

    [_logLock lock];

    [self.logRecord addObject:log];
    [self persistJailbreakLogLine:log];

    if (!self.logView) {
        [_logLock unlock];
        return;
    }

    BOOL isDebug = self.logView.class == DODebugLogView.class;
    if (debug && !isDebug) {
        [_logLock unlock];
        return;
    }

    if (update) {
        if ([self.logView respondsToSelector:@selector(updateLog:)]) {
            [self.logView updateLog:log];
        }
    }
    else {
        [self.logView showLog:log];
    }
    [_logLock unlock];
}

- (void)sendLog:(NSString*)log debug:(BOOL)debug
{
    [self sendLog:log debug:debug update:NO];
}

- (void)shareLogRecordFromView:(UIView *)sourceView
{
    NSString *log = [self.logRecord componentsJoinedByString:@"\n"];
    if (log.length == 0) log = [self lastJailbreakLog];
    if (log.length == 0)
        return;
    UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[log] applicationActivities:nil];
    activityViewController.popoverPresentationController.sourceView = sourceView;
    activityViewController.popoverPresentationController.sourceRect = sourceView.bounds;
    [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:activityViewController animated:YES completion:nil];
}

- (void)completeJailbreak
{
    if (!self.logView)
        return;

    [self.logView didComplete];
}

- (void)failLastLog
{
    if (!self.logView)
        return;

    if ([self.logView respondsToSelector:@selector(didFail)]) {
        [self.logView didFail];
    }
}

- (void)observeFileDescriptor:(int)fd withCallback:(void (^)(char *line))callbackBlock
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int stdout_pipe[2];
        int stdout_orig[2];
        if (pipe(stdout_pipe) != 0 || pipe(stdout_orig) != 0) {
            return;
        }

        dup2(fd, stdout_orig[1]);
        close(stdout_orig[0]);
        
        dup2(stdout_pipe[1], fd);
        close(stdout_pipe[1]);
        
        char cur = 0;
        char line[1024];
        int line_index = 0;
        ssize_t bytes_read;

        while ((bytes_read = read(stdout_pipe[0], &cur, sizeof(cur))) > 0) {
            @autoreleasepool {
                write(stdout_orig[1], &cur, bytes_read);

                if (cur == '\n') {
                    line[line_index] = '\0';
                    callbackBlock(line);
                    line_index = 0;
                } else {
                    if (line_index < sizeof(line) - 1) {
                        line[line_index++] = cur;
                    }
                }
            }
        }
        close(stdout_pipe[0]);
    });
}

- (void)startLogCapture
{
    [_logLock lock];
    [self.logRecord removeAllObjects];

    NSString *previousPath = [_documentsDirectory stringByAppendingPathComponent:@"jailbreak.previous.log"];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:self.jailbreakLogPath]) {
        [fileManager removeItemAtPath:previousPath error:nil];
        [fileManager copyItemAtPath:self.jailbreakLogPath toPath:previousPath error:nil];
    }

    const char *path = self.jailbreakLogPath.fileSystemRepresentation;
    if (_logFileFd >= 0) {
        close(_logFileFd);
        _logFileFd = -1;
    }
    // Keep this inode open for the rest of the run. Re-opening after uid 0 can fail.
    _logFileFd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
    if (_logFileFd >= 0) {
        fchmod(_logFileFd, 0644);
    } else {
        NSLog(@"jailbreak.log open failed: errno=%d (%s) path=%s", errno, strerror(errno), path);
    }

    NSString *header = [NSString stringWithFormat:@"===== jailbreak %@ path=%@ uid=%d =====", [NSDate date], self.jailbreakLogPath, getuid()];
    [_logLock unlock];
    [self persistJailbreakLogLine:header];

    [self observeFileDescriptor:STDOUT_FILENO withCallback:^(char *line) {
        NSString *str = [NSString stringWithUTF8String:line];
        [self sendLog:str debug:YES];
    }];
    
    [self observeFileDescriptor:STDERR_FILENO withCallback:^(char *line) {
        NSString *str = [NSString stringWithUTF8String:line];
        [self sendLog:str debug:YES];
    }];
}

- (NSString *)localizedStringForKey:(NSString*)key
{
    NSString *candidate = NSLocalizedString(key, nil);
    if ([candidate isEqualToString:key]) {
        if (!_fallbackLocalizations) {
            _fallbackLocalizations = [NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"en.lproj/Localizable.strings"]];
        }
        candidate = _fallbackLocalizations[key];
        if (!candidate) candidate = key;
    }
    return candidate;
}

- (UIImage *)renderBootLogo
{
    return [[[DOThemeManager sharedInstance] enabledTheme] generateBootLogo];
}

@end


NSString *DOLocalizedString(NSString *key)
{
    return [[DOUIManager sharedInstance] localizedStringForKey:key];
}
