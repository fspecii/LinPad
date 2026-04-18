//
//  CurrentRoot.m
//  iSH
//
//  Created by Theodore Dubois on 11/4/21.
//

#import "CurrentRoot.h"
#include "kernel/calls.h"
#include "fs/path.h"

#ifdef ISH_LINUX
#import "LinuxInterop.h"
#endif

int fs_ish_version;
int fs_ish_apk_version;

#if !ISH_LINUX
static ssize_t read_file(const char *path, char *buf, size_t size) {
    struct fd *fd = generic_open(path, O_RDONLY_, 0);
    if (IS_ERR(fd))
        return PTR_ERR(fd);
    ssize_t n = fd->ops->read(fd, buf, size);
    fd_close(fd);
    if (n == size)
        return _ENAMETOOLONG;
    return n;
}

static ssize_t write_file(const char *path, const char *buf, size_t size) {
    struct fd *fd = generic_open(path, O_WRONLY_|O_CREAT_|O_TRUNC_, 0644);
    if (IS_ERR(fd))
        return PTR_ERR(fd);
    ssize_t n = fd->ops->write(fd, buf, size);
    fd_close(fd);
    return n;
}
static int remove_directory(const char *path) {
    return generic_rmdirat(AT_PWD, path);
}
#else
#define read_file linux_read_file
#define write_file linux_write_file
#define remove_directory linux_remove_directory
#endif

void FsInitialize(void) {
    // /ish/version is the last ish version that opened this root. Used to migrate the filesystem.
    char buf[1000];
    ssize_t n = read_file("/ish/version", buf, sizeof(buf));
    if (n >= 0) {
        NSString *currentVersion = NSBundle.mainBundle.infoDictionary[(__bridge NSString *) kCFBundleVersionKey];
        NSString *currentVersionFile = [NSString stringWithFormat:@"%@\n", currentVersion];

        NSString *version = [[NSString alloc] initWithBytesNoCopy:buf length:n encoding:NSUTF8StringEncoding freeWhenDone:NO];
        version = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        fs_ish_version = version.intValue;

        version = nil;

        n = read_file("/ish/apk-version", buf, sizeof(buf));
        if (n >= 0) {
            NSString *version = [[NSString alloc] initWithBytesNoCopy:buf length:n encoding:NSUTF8StringEncoding freeWhenDone:NO];
            version = [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            fs_ish_apk_version = version.intValue;
        }

        // If no newer value for CURRENT_APK_VERSION, do silent update.
        if (fs_ish_apk_version >= CURRENT_APK_VERSION)
            FsUpdateRepositories();

        if (currentVersion.intValue > fs_ish_version) {
            fs_ish_version = currentVersion.intValue;
            write_file("/ish/version", currentVersionFile.UTF8String, [currentVersionFile lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        }
    }

    // Apply rootfs overlay patches (e.g. fetch-polyfill.js)
    FsApplyOverlay();
}

bool FsIsManaged(void) {
    return fs_ish_version != 0;
}

bool FsNeedsRepositoryUpdate(void) {
    return FsIsManaged() && fs_ish_apk_version < CURRENT_APK_VERSION;
}

void FsUpdateOnlyRepositoriesFile(void) {
    NSURL *repositories = [NSBundle.mainBundle URLForResource:@"repositories" withExtension:@"txt"];
    if (repositories != nil) {
        NSMutableData *repositoriesData = [@"# This file contains pinned repositories managed by iSH. If the /ish directory\n"
                                           @"# exists, iSH uses the metadata stored in it to keep this file up to date (by\n"
                                           @"# overwriting the contents on boot.)\n" dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
        [repositoriesData appendData:[NSData dataWithContentsOfURL:repositories]];
        write_file("/etc/apk/repositories", repositoriesData.bytes, repositoriesData.length);
    }
}

void FsUpdateRepositories(void) {
    FsUpdateOnlyRepositoriesFile();
    fs_ish_apk_version = CURRENT_APK_VERSION;
    NSString *currentVersionFile = [NSString stringWithFormat:@"%d\n", fs_ish_apk_version];
    write_file("/ish/apk-version", currentVersionFile.UTF8String, [currentVersionFile lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    remove_directory("/ish/apk");
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:FsUpdatedNotification object:nil];
    });
}

void FsApplyOverlay(void) {
    // Locate RootfsPatch.bundle inside the app bundle
    NSURL *patchBundleURL = [NSBundle.mainBundle URLForResource:@"RootfsPatch" withExtension:@"bundle"];
    if (patchBundleURL == nil) {
        NSLog(@"[RootfsPatch] bundle not found in app, skipping overlay");
        return;
    }
    NSBundle *patchBundle = [NSBundle bundleWithURL:patchBundleURL];
    if (patchBundle == nil) {
        NSLog(@"[RootfsPatch] failed to load bundle at %@", patchBundleURL);
        return;
    }

    // Read manifest
    NSURL *manifestURL = [patchBundle URLForResource:@"manifest" withExtension:@"plist"];
    if (manifestURL == nil) {
        NSLog(@"[RootfsPatch] manifest.plist not found in bundle");
        return;
    }
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfURL:manifestURL];
    if (manifest == nil) {
        NSLog(@"[RootfsPatch] failed to parse manifest.plist");
        return;
    }

    int patchVersion = [manifest[@"version"] intValue];
    if (patchVersion <= 0)
        return;

    // Check installed overlay version in guest fs
    char buf[100];
    int installedVersion = 0;
    ssize_t n = read_file("/ish/overlay-version", buf, sizeof(buf));
    if (n > 0) {
        buf[n] = '\0';
        installedVersion = atoi(buf);
    }
    if (installedVersion >= patchVersion) {
        NSLog(@"[RootfsPatch] v%d already installed (bundle v%d), skipping", installedVersion, patchVersion);
        return;
    }

    NSLog(@"[RootfsPatch] applying v%d (installed v%d)", patchVersion, installedVersion);

    // Apply each file from the manifest
    NSArray *files = manifest[@"files"];
    if (files == nil)
        return;

    int applied = 0, failed = 0;
    for (NSDictionary *entry in files) {
        NSString *src = entry[@"src"];
        NSString *dst = entry[@"dst"];
        if (src == nil || dst == nil)
            continue;

        // Ensure parent directories exist in guest fs
        NSString *parentDir = [dst stringByDeletingLastPathComponent];
        if (parentDir.length > 1)
            generic_mkdirat(AT_PWD, parentDir.UTF8String, 0755);

        // Read file from patch bundle
        NSURL *srcURL = [patchBundle.bundleURL URLByAppendingPathComponent:src];
        NSData *data = [NSData dataWithContentsOfURL:srcURL];
        if (data == nil) {
            NSLog(@"[RootfsPatch] SKIP %@ (not found in bundle)", src);
            failed++;
            continue;
        }

        ssize_t written = write_file(dst.UTF8String, data.bytes, data.length);
        if (written < 0) {
            NSLog(@"[RootfsPatch] FAIL %@ -> %@ (error %zd)", src, dst, written);
            failed++;
        } else {
            NSLog(@"[RootfsPatch] OK %@ -> %@ (%lu bytes)", src, dst, (unsigned long)data.length);
            applied++;
        }
    }

    // Record installed version
    generic_mkdirat(AT_PWD, "/ish", 0755);
    NSString *versionStr = [NSString stringWithFormat:@"%d\n", patchVersion];
    write_file("/ish/overlay-version", versionStr.UTF8String,
               [versionStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);

    NSLog(@"[RootfsPatch] done: %d applied, %d failed, now at v%d", applied, failed, patchVersion);
}

NSString *const FsUpdatedNotification = @"FsUpdatedNotification";
