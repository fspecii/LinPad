//
//  Roots.m
//  iSH
//
//  Created by Theodore Dubois on 6/7/20.
//

#import <FileProvider/FileProvider.h>
#import "Roots.h"
#import "AppGroup.h"
#import "NSObject+SaneKVO.h"
#include <copyfile.h>
#include <sqlite3.h>
#include <sys/stat.h>
#include "tools/fakefs.h"

static NSURL *RootsDir(void) {
    static NSURL *rootsDir;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        rootsDir = [ContainerURL() URLByAppendingPathComponent:@"roots"];
        NSFileManager *manager = [NSFileManager defaultManager];
        [manager createDirectoryAtURL:rootsDir
          withIntermediateDirectories:YES
                           attributes:@{}
                                error:nil];
    });
    return rootsDir;
}

/// Imports and updates are unpacked here and moved into RootsDir() only when complete, so
/// a kill mid-import never leaves a partial root behind. Anything here at launch is stale.
static NSURL *StagingDir(void) {
    return [ContainerURL() URLByAppendingPathComponent:@"roots-staging"];
}

/// A rootfs downloaded from a release: root.tar.gz and root.version, like the bundle's.
static NSURL *DownloadedRootDir(void) {
    return [ContainerURL() URLByAppendingPathComponent:@"system-update"];
}

static NSString *kDefaultRoot = @"Default Root";
static NSString *kPendingUpdate = @"linux.pendingSystemUpdate";
static NSString *kPendingFactoryReset = @"linux.pendingFactoryReset";
static NSString *kPendingRollback = @"linux.pendingSystemRollback";
NSString *const RootsFactoryResetKeepFiles = @"keep-files";
NSString *const RootsFactoryResetErase = @"erase";
/// iOSFS's remembered iPad folder mounts (app/iOSFS.m), mount point → bookmark.
static NSString *kMountBookmarks = @"iOS Mount Bookmarks";
/// A factory reset moves the replaced root here (RootsDir()/.reset-old.<name>) and deletes it
/// once the new root is in place. Dot names are not roots.
static NSString *kResetTrashPrefix = @".reset-old.";

static void DeleteInBackground(NSURL *url) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    });
}

/// Finishes a factory reset that was interrupted: a root moved aside with no replacement
/// in place goes back; one whose replacement is in place is deleted.
static void RecoverInterruptedFactoryReset(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *entry in [fm contentsOfDirectoryAtPath:RootsDir().path error:nil]) {
        if (![entry hasPrefix:kResetTrashPrefix] || entry.length == kResetTrashPrefix.length)
            continue;
        NSURL *trash = [RootsDir() URLByAppendingPathComponent:entry];
        NSURL *original = [RootsDir() URLByAppendingPathComponent:[entry substringFromIndex:kResetTrashPrefix.length]];
        if (![fm fileExistsAtPath:original.path] && [fm moveItemAtURL:trash toURL:original error:nil])
            continue;
        DeleteInBackground(trash);
    }
}

@interface Roots ()
@property NSMutableOrderedSet<NSString *> *roots;
@property BOOL updatingDomains;
@property BOOL domainsNeedUpdate;
@property BOOL wantsVersionFile;
@end

@implementation Roots

- (instancetype)init {
    if (self = [super init]) {
        NSError *error = nil;
        RecoverInterruptedFactoryReset();
        NSArray<NSString *> *rootNames = [NSFileManager.defaultManager contentsOfDirectoryAtPath:RootsDir().path error:&error];
        NSAssert(error == nil, @"couldn't list roots: %@", error);
        NSMutableOrderedSet<NSString *> *roots = [NSMutableOrderedSet new];
        for (NSString *name in rootNames) {
            if (![name hasPrefix:@"."])
                [roots addObject:name];
        }
        self.roots = roots;
        [NSFileManager.defaultManager removeItemAtURL:StagingDir() error:nil];
        // The bundled root is imported by the app delegate (importBundledRootWithProgress:),
        // off the main thread when the desktop shows progress for it.
        [self observe:@[@"roots"] options:0 owner:self usingBlock:^(typeof(self) self) {
            if (self.defaultRoot == nil && self.roots.count)
                self.defaultRoot = self.roots[0];
            [self syncFileProviderDomains];
        }];
        [self syncFileProviderDomains];

        if ((!self.defaultRoot || ![self.roots containsObject:self.defaultRoot]) && self.roots.count)
            self.defaultRoot = self.roots.firstObject;
        [self discardStaleDownloadedRoot];
    }
    return self;
}

- (NSString *)defaultRoot {
    return [NSUserDefaults.standardUserDefaults stringForKey:kDefaultRoot];
}
- (void)setDefaultRoot:(NSString *)defaultRoot {
    [NSUserDefaults.standardUserDefaults setObject:defaultRoot forKey:kDefaultRoot];
}

- (NSURL *)rootUrl:(NSString *)name {
    return [RootsDir() URLByAppendingPathComponent:name];
}

- (void)syncFileProviderDomains {
    if (self.updatingDomains) {
        self.domainsNeedUpdate = YES;
        return;
    }
    self.updatingDomains = YES;
    self.domainsNeedUpdate = NO;

    [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
        void (^onError)(NSError *error) = ^(NSError *error) {
            if (error != nil)
                NSLog(@"error adjusting domains: %@", error);
        };
        onError(error);
        NSMutableOrderedSet<NSString *> *missingRoots = [self.roots mutableCopy];
        for (NSFileProviderDomain *domain in domains) {
            if ([missingRoots containsObject:domain.identifier]) {
                [missingRoots removeObject:domain.identifier];
            } else {
                [NSFileManager.defaultManager removeItemAtURL:
                 [NSFileProviderManager.defaultManager.documentStorageURL
                  URLByAppendingPathComponent:domain.pathRelativeToDocumentStorage]
                                                        error:nil];
                [NSFileProviderManager removeDomain:domain completionHandler:onError];
            }
        }
        for (NSString *rootId in missingRoots) {
            [NSFileProviderManager addDomain:[[NSFileProviderDomain alloc] initWithIdentifier:rootId
                                                                                  displayName:rootId
                                                                pathRelativeToDocumentStorage:rootId]
                           completionHandler:onError];
        }
        if (self.domainsNeedUpdate)
            [self syncFileProviderDomains];
        self.updatingDomains = NO;
    }];
}

- (BOOL)accessInstanceVariablesDirectly {
    return YES;
}

void root_progress_callback(void *cookie, double progress, const char *message, bool *should_cancel) {
    id <ProgressReporter> reporter = (__bridge id<ProgressReporter>) cookie;
    [reporter updateProgress:progress message:[NSString stringWithUTF8String:message]];
    if ([reporter shouldCancel])
        *should_cancel = true;
}

- (BOOL)importRootFromArchive:(NSURL *)archive name:(NSString *)name error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress {
    NSAssert(![self.roots containsObject:name], @"root already exists: %@", name);
    struct fakefsify_error fs_err;
    NSURL *destination = [self rootUrl:name];
    [NSFileManager.defaultManager createDirectoryAtURL:StagingDir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *tempDestination = [StagingDir() URLByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]];
    if (!fakefs_import(archive.fileSystemRepresentation,
                       tempDestination.fileSystemRepresentation,
                       &fs_err, (struct progress) {(__bridge void *) progress, root_progress_callback})) {
        NSString *domain = NSPOSIXErrorDomain;
        if (fs_err.type == ERR_SQLITE)
            domain = @"SQLite";
        *error = [NSError errorWithDomain:domain
                                     code:fs_err.code
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"%s, line %d", fs_err.message, fs_err.line]}];
        if (fs_err.type == ERR_CANCELLED)
            *error = nil;
        free(fs_err.message);
        [NSFileManager.defaultManager removeItemAtURL:tempDestination error:nil];
        return NO;
    }
    if (![NSFileManager.defaultManager moveItemAtURL:tempDestination toURL:destination error:error])
        return NO;

    void (^addRoot)(void) = ^{
        [[self mutableOrderedSetValueForKey:@"roots"] addObject:name];
    };
    if (!NSThread.isMainThread)
        dispatch_sync(dispatch_get_main_queue(), addRoot);
    else
        addRoot();
    return YES;
}

- (BOOL)exportRootNamed:(NSString *)name toArchive:(NSURL *)archive error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress {
    NSAssert([self.roots containsObject:name], @"trying to export a root that doesn't exist: %@", name);
    struct fakefsify_error fs_err;
    if (!fakefs_export([self rootUrl:name].fileSystemRepresentation,
                       archive.fileSystemRepresentation,
                       &fs_err, (struct progress) {(__bridge void *) progress, root_progress_callback})) {
        // TODO: dedup with above method
        NSString *domain = NSPOSIXErrorDomain;
        if (fs_err.type == ERR_SQLITE)
            domain = @"SQLite";
        *error = [NSError errorWithDomain:domain
                                     code:fs_err.code
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:fs_err.message]}];
        if (fs_err.type == ERR_CANCELLED)
            *error = nil;
        free(fs_err.message);
        return NO;
    }
    return YES;
}

- (BOOL)destroyRootNamed:(NSString *)name error:(NSError **)error {
    if ([name isEqualToString:self.defaultRoot]) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Cannot delete the default filesystem"}];
        return NO;
    }
    NSAssert([self.roots containsObject:name], @"root does not exist: %@", name);
    if (![NSFileManager.defaultManager removeItemAtURL:[self rootUrl:name] error:error])
        return NO;
    [[self mutableOrderedSetValueForKey:@"roots"] removeObject:name];
    return YES;
}

- (BOOL)renameRoot:(NSString *)name toName:(NSString *)newName error:(NSError **)error {
    if (name.length == 0) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't be empty"}];
        return NO;
    }
    if ([name containsString:@"/"]) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't contain /"}];
        return NO;
    }
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't be . or .."}];
        return NO;
    }
    if ([name isEqualToString:self.defaultRoot]) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Cannot rename the default filesystem"}];
        return NO;
    }
    NSAssert([self.roots containsObject:name], @"root does not exist: %@", name);
    
    if (![NSFileManager.defaultManager moveItemAtURL:[self rootUrl:name] toURL:[self rootUrl:newName] error:error])
        return NO;
    NSUInteger index = [self.roots indexOfObject:name];
    [[self mutableOrderedSetValueForKey:@"roots"] replaceObjectAtIndex:index withObject:newName];
    return YES;
}

#pragma mark - Bundled root, versions and updates

- (NSURL *)bundledRootArchive {
    return [NSBundle.mainBundle URLForResource:@"root" withExtension:@"tar.gz"];
}

static NSString *ReadVersion(NSURL *url) {
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}

- (NSString *)bundledRootVersion {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"root" withExtension:@"version"];
    return url ? ReadVersion(url) : nil;
}

- (NSString *)installedRootVersion {
    if (self.needsDefaultRoot)
        return nil;
    return ReadVersion([self.defaultRootUrl URLByAppendingPathComponent:@"data/usr/share/ish/rootfs-version"]);
}

- (NSURL *)defaultRootUrl {
    return [self rootUrl:self.defaultRoot ?: @"default"];
}

- (BOOL)needsDefaultRoot {
    return self.roots.count == 0;
}

- (BOOL)importBundledRootWithProgress:(id<ProgressReporter>)progress error:(NSError **)error {
    NSURL *archive = self.bundledRootArchive;
    if (archive == nil) {
        *error = [NSError errorWithDomain:@"iSH" code:ENOENT userInfo:@{NSLocalizedDescriptionKey: @"The app has no bundled root filesystem"}];
        return NO;
    }
    if (![self importRootFromArchive:archive name:@"default" error:error progressReporter:progress])
        return NO;
    _wantsVersionFile = YES;
    return YES;
}

- (NSURL *)downloadedRootArchive {
    NSURL *archive = [DownloadedRootDir() URLByAppendingPathComponent:@"root.tar.gz"];
    return [NSFileManager.defaultManager fileExistsAtPath:archive.path] && self.downloadedRootVersion ? archive : nil;
}

- (NSString *)downloadedRootVersion {
    return ReadVersion([DownloadedRootDir() URLByAppendingPathComponent:@"root.version"]);
}

- (BOOL)storeDownloadedRootArchive:(NSURL *)archive version:(NSString *)version error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *dir = DownloadedRootDir();
    [fm removeItemAtURL:dir error:nil];
    if (![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:error])
        return NO;
    // The version goes in last: without it the archive does not count.
    if (![fm moveItemAtURL:archive toURL:[dir URLByAppendingPathComponent:@"root.tar.gz"] error:error] ||
        ![[version stringByAppendingString:@"\n"] writeToURL:[dir URLByAppendingPathComponent:@"root.version"]
                                                  atomically:YES encoding:NSUTF8StringEncoding error:error]) {
        [fm removeItemAtURL:dir error:nil];
        return NO;
    }
    return YES;
}

/// A downloaded system no newer than the bundled or the installed one is never used again.
- (void)discardStaleDownloadedRoot {
    NSString *downloaded = self.downloadedRootVersion;
    if (downloaded == nil) {
        [NSFileManager.defaultManager removeItemAtURL:DownloadedRootDir() error:nil];
        return;
    }
    NSString *bundled = self.bundledRootVersion, *installed = self.installedRootVersion;
    if ((bundled && downloaded.longLongValue <= bundled.longLongValue) ||
        (installed && downloaded.longLongValue <= installed.longLongValue))
        [NSFileManager.defaultManager removeItemAtURL:DownloadedRootDir() error:nil];
}

- (BOOL)prefersDownloadedRoot {
    NSString *downloaded = self.downloadedRootVersion;
    if (downloaded == nil || self.downloadedRootArchive == nil)
        return NO;
    NSString *bundled = self.bundledRootArchive ? self.bundledRootVersion : nil;
    return bundled == nil || downloaded.longLongValue > bundled.longLongValue;
}

- (NSURL *)updateRootArchive {
    return self.prefersDownloadedRoot ? self.downloadedRootArchive : self.bundledRootArchive;
}

- (NSString *)updateRootVersion {
    return self.prefersDownloadedRoot ? self.downloadedRootVersion : (self.bundledRootArchive ? self.bundledRootVersion : nil);
}

- (NSString *)availableUpdate {
    NSString *candidate = self.updateRootVersion;
    if (candidate == nil || self.needsDefaultRoot || self.updateRootArchive == nil)
        return nil;
    NSString *installed = self.installedRootVersion;
    if (installed != nil && candidate.longLongValue <= installed.longLongValue)
        return nil;
    return candidate;
}

- (NSString *)pendingUpdate {
    return [NSUserDefaults.standardUserDefaults stringForKey:kPendingUpdate];
}
- (void)setPendingUpdate:(NSString *)pendingUpdate {
    [NSUserDefaults.standardUserDefaults setObject:pendingUpdate forKey:kPendingUpdate];
}

// User data carried from the old root into the updated one. Everything else (the system:
// /usr, /lib, /bin, /sbin, /etc, /var/lib/apk, ...) comes from the new rootfs.
static NSArray<NSString *> *UpdateKeptPaths(void) {
    return @[@"/root", @"/home", @"/opt", @"/srv",
             @"/etc/passwd", @"/etc/group", @"/etc/shadow", @"/etc/gshadow",
             @"/etc/hostname", @"/etc/hosts", @"/etc/ish/firstrun.json", @"/etc/ishwl/options"];
}

#define UPDATE_SQL(stmt) do { if ((stmt) != SQLITE_OK) goto sql_error; } while (0)

/// Rows for `prefix` itself and everything below it (paths are blobs: "/root", "/root/x").
static int BindPrefix(sqlite3_stmt *stmt, int first, const char *prefix) {
    size_t length = strlen(prefix);
    char upper[PATH_MAX];
    snprintf(upper, sizeof(upper), "%s0", prefix); // '0' sorts right after '/'
    sqlite3_bind_blob(stmt, first, prefix, (int) length, SQLITE_TRANSIENT);
    char lower[PATH_MAX];
    snprintf(lower, sizeof(lower), "%s/", prefix);
    sqlite3_bind_blob(stmt, first + 1, lower, (int) strlen(lower), SQLITE_TRANSIENT);
    return sqlite3_bind_blob(stmt, first + 2, upper, (int) strlen(upper), SQLITE_TRANSIENT);
}

/// Copies `kept` paths (with their fakefs metadata and file contents) from the root at
/// `old` into the freshly imported root at `new`, replacing what the new root has there.
/// File contents are APFS clones, so this costs no space and little time.
static BOOL CarryUserData(NSURL *old, NSURL *new, NSArray<NSString *> *kept, NSString **message) {
    sqlite3 *db = NULL;
    sqlite3_stmt *exists = NULL, *select = NULL, *deletePaths = NULL, *insertStat = NULL, *insertPath = NULL;
    BOOL ok = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *oldData = [old URLByAppendingPathComponent:@"data"].path;
    NSString *newData = [new URLByAppendingPathComponent:@"data"].path;
    NSString *attach = [NSString stringWithFormat:@"attach database '%@' as old",
                        [[old URLByAppendingPathComponent:@"meta.db"].path stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];

    if (sqlite3_open_v2([new URLByAppendingPathComponent:@"meta.db"].fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK)
        goto sql_error;
    sqlite3_busy_timeout(db, 5000);
    UPDATE_SQL(sqlite3_exec(db, attach.UTF8String, NULL, NULL, NULL));
    UPDATE_SQL(sqlite3_exec(db, "begin", NULL, NULL, NULL));
    UPDATE_SQL(sqlite3_prepare_v2(db, "select count(*) from old.paths where path = ?1 or (path >= ?2 and path < ?3)", -1, &exists, NULL));
    UPDATE_SQL(sqlite3_prepare_v2(db, "select p.path, p.inode, s.stat from old.paths p join old.stats s on s.inode = p.inode "
                                      "where p.path = ?1 or (p.path >= ?2 and p.path < ?3) order by p.path", -1, &select, NULL));
    UPDATE_SQL(sqlite3_prepare_v2(db, "delete from main.paths where path = ?1 or (path >= ?2 and path < ?3)", -1, &deletePaths, NULL));
    UPDATE_SQL(sqlite3_prepare_v2(db, "insert into main.stats (stat) values (?)", -1, &insertStat, NULL));
    UPDATE_SQL(sqlite3_prepare_v2(db, "insert or replace into main.paths (path, inode) values (?, ?)", -1, &insertPath, NULL));

    for (NSString *keep in kept) {
        const char *prefix = keep.UTF8String;
        BindPrefix(exists, 1, prefix);
        if (sqlite3_step(exists) != SQLITE_ROW)
            goto sql_error;
        sqlite3_int64 count = sqlite3_column_int64(exists, 0);
        sqlite3_reset(exists);
        if (count == 0)
            continue; // the old root never had it: keep the new root's

        BindPrefix(deletePaths, 1, prefix);
        if (sqlite3_step(deletePaths) != SQLITE_DONE)
            goto sql_error;
        sqlite3_reset(deletePaths);
        [fm removeItemAtPath:[newData stringByAppendingString:keep] error:nil];

        NSMutableDictionary<NSNumber *, NSNumber *> *inodes = [NSMutableDictionary new];
        BindPrefix(select, 1, prefix);
        int step;
        while ((step = sqlite3_step(select)) == SQLITE_ROW) {
            NSString *path = [[NSString alloc] initWithBytes:sqlite3_column_blob(select, 0)
                                                      length:sqlite3_column_bytes(select, 0)
                                                    encoding:NSUTF8StringEncoding];
            if (path == nil)
                continue;
            NSNumber *oldInode = @(sqlite3_column_int64(select, 1));
            NSNumber *newInode = inodes[oldInode];
            if (newInode == nil) {
                sqlite3_bind_blob(insertStat, 1, sqlite3_column_blob(select, 2), sqlite3_column_bytes(select, 2), SQLITE_TRANSIENT);
                if (sqlite3_step(insertStat) != SQLITE_DONE)
                    goto sql_error;
                sqlite3_reset(insertStat);
                newInode = @(sqlite3_last_insert_rowid(db));
                inodes[oldInode] = newInode;
            }
            sqlite3_bind_blob(insertPath, 1, path.UTF8String, (int) strlen(path.UTF8String), SQLITE_TRANSIENT);
            sqlite3_bind_int64(insertPath, 2, newInode.longLongValue);
            if (sqlite3_step(insertPath) != SQLITE_DONE)
                goto sql_error;
            sqlite3_reset(insertPath);

            // The backing file: directories are made, everything else (regular files,
            // symlinks, which fakefs stores as files, device placeholders) is cloned.
            NSString *src = [oldData stringByAppendingString:path];
            NSString *dst = [newData stringByAppendingString:path];
            struct stat st;
            if (lstat(src.fileSystemRepresentation, &st) < 0)
                continue;
            [fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if (S_ISDIR(st.st_mode)) {
                mkdir(dst.fileSystemRepresentation, 0777);
            } else if (S_ISFIFO(st.st_mode)) {
                mkfifo(dst.fileSystemRepresentation, 0666);
            } else if (copyfile(src.fileSystemRepresentation, dst.fileSystemRepresentation, NULL,
                                COPYFILE_CLONE | COPYFILE_DATA | COPYFILE_NOFOLLOW) < 0) {
                *message = [NSString stringWithFormat:@"copying %@: %s", path, strerror(errno)];
                goto done;
            }
        }
        sqlite3_reset(select);
        if (step != SQLITE_DONE)
            goto sql_error;
    }
    UPDATE_SQL(sqlite3_exec(db, "delete from main.stats where inode not in (select inode from main.paths)", NULL, NULL, NULL));
    UPDATE_SQL(sqlite3_exec(db, "commit", NULL, NULL, NULL));
    ok = YES;
    goto done;

sql_error:
    *message = [NSString stringWithFormat:@"database: %s", db ? sqlite3_errmsg(db) : "cannot open"];
done:
    sqlite3_finalize(exists);
    sqlite3_finalize(select);
    sqlite3_finalize(deletePaths);
    sqlite3_finalize(insertStat);
    sqlite3_finalize(insertPath);
    if (db != NULL) {
        if (!ok)
            sqlite3_exec(db, "rollback", NULL, NULL, NULL);
        sqlite3_close(db);
    }
    return ok;
}

static NSOrderedSet<NSString *> *WorldPackages(NSURL *root) {
    NSString *text = [NSString stringWithContentsOfURL:[root URLByAppendingPathComponent:@"data/etc/apk/world"]
                                              encoding:NSUTF8StringEncoding error:nil];
    NSMutableOrderedSet *packages = [NSMutableOrderedSet new];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (line.length)
            [packages addObject:line];
    }
    return packages;
}

/// Packages in the old world file that the new system lacks are listed in
/// /etc/ish/reinstall-packages, which the guest's first-run hook installs (ish-firstrun).
/// The file must have fakefs metadata to be visible in the guest, so its row is cloned
/// from /etc/apk/world's (a root-owned 0644 file).
static void ListPackagesToReinstall(NSURL *old, NSURL *new) {
    NSMutableOrderedSet<NSString *> *missing = [WorldPackages(old) mutableCopy];
    [missing minusOrderedSet:WorldPackages(new)];
    if (missing.count == 0)
        return;
    NSString *list = [[missing.array componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    NSURL *file = [new URLByAppendingPathComponent:@"data/etc/ish/reinstall-packages"];
    [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![list writeToURL:file atomically:NO encoding:NSUTF8StringEncoding error:nil])
        return;
    sqlite3 *db;
    if (sqlite3_open_v2([new URLByAppendingPathComponent:@"meta.db"].fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK) {
        sqlite3_exec(db, "insert into stats (stat) select stat from stats where inode = (select inode from paths where path = cast('/etc' as blob)) "
                         "and not exists (select 1 from paths where path = cast('/etc/ish' as blob));"
                         "insert into paths (path, inode) select cast('/etc/ish' as blob), last_insert_rowid() "
                         "where not exists (select 1 from paths where path = cast('/etc/ish' as blob));"
                         "insert into stats (stat) select stat from stats where inode = (select inode from paths where path = cast('/etc/apk/world' as blob));"
                         "insert or replace into paths (path, inode) values (cast('/etc/ish/reinstall-packages' as blob), last_insert_rowid());",
                     NULL, NULL, NULL);
    }
    sqlite3_close(db);
}

- (BOOL)updateDefaultRootWithProgress:(id<ProgressReporter>)progress error:(NSError **)error {
    NSString *name = self.defaultRoot;
    NSURL *archive = self.updateRootArchive;
    BOOL fromDownload = self.prefersDownloadedRoot;
    if (name == nil || archive == nil || self.needsDefaultRoot) {
        *error = [NSError errorWithDomain:@"iSH" code:ENOENT userInfo:@{NSLocalizedDescriptionKey: @"Nothing to update"}];
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *old = [self rootUrl:name];
    [fm createDirectoryAtURL:StagingDir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *staged = [StagingDir() URLByAppendingPathComponent:[@"update-" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];

    struct fakefsify_error fs_err;
    if (!fakefs_import(archive.fileSystemRepresentation, staged.fileSystemRepresentation, &fs_err,
                       (struct progress) {(__bridge void *) progress, root_progress_callback})) {
        *error = [NSError errorWithDomain:fs_err.type == ERR_SQLITE ? @"SQLite" : NSPOSIXErrorDomain code:fs_err.code
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%s, line %d", fs_err.message, fs_err.line]}];
        free(fs_err.message);
        [fm removeItemAtURL:staged error:nil];
        return NO;
    }
    [progress updateProgress:1 message:@"Keeping your files…"];
    NSString *message = nil;
    if (!CarryUserData(old, staged, UpdateKeptPaths(), &message)) {
        *error = [NSError errorWithDomain:@"iSH" code:EIO userInfo:@{NSLocalizedDescriptionKey: message ?: @"could not keep user data"}];
        [fm removeItemAtURL:staged error:nil];
        return NO;
    }
    ListPackagesToReinstall(old, staged);

    // Swap: the old root stays, renamed, until the user deletes it (Settings > Filesystems).
    NSString *previous = [NSString stringWithFormat:@"%@ (before update %@)", name, self.installedRootVersion ?: @"unversioned"];
    while ([self.roots containsObject:previous] || [fm fileExistsAtPath:[self rootUrl:previous].path])
        previous = [previous stringByAppendingString:@"+"];
    if (![fm moveItemAtURL:old toURL:[self rootUrl:previous] error:error]) {
        [fm removeItemAtURL:staged error:nil];
        return NO;
    }
    if (![fm moveItemAtURL:staged toURL:old error:error]) {
        // Put the old system back rather than leave no default root.
        [fm moveItemAtURL:[self rootUrl:previous] toURL:old error:nil];
        [fm removeItemAtURL:staged error:nil];
        return NO;
    }
    void (^addRoot)(void) = ^{
        [[self mutableOrderedSetValueForKey:@"roots"] addObject:previous];
    };
    if (!NSThread.isMainThread)
        dispatch_sync(dispatch_get_main_queue(), addRoot);
    else
        addRoot();
    if (fromDownload)
        [fm removeItemAtURL:DownloadedRootDir() error:nil];
    return YES;
}

#pragma mark - Rollback

- (NSString *)previousRootName {
    NSString *name = self.defaultRoot;
    if (name == nil)
        return nil;
    NSString *prefix = [name stringByAppendingString:@" (before update "];
    NSString *best = nil;
    long long bestVersion = -1;
    for (NSString *root in self.roots) {
        if (![root hasPrefix:prefix])
            continue;
        NSString *version = ReadVersion([[self rootUrl:root] URLByAppendingPathComponent:@"data/usr/share/ish/rootfs-version"]);
        long long value = version.longLongValue;
        if (best == nil || value > bestVersion) {
            best = root;
            bestVersion = value;
        }
    }
    return best;
}

- (NSString *)previousRootVersion {
    NSString *previous = self.previousRootName;
    return previous ? ReadVersion([[self rootUrl:previous] URLByAppendingPathComponent:@"data/usr/share/ish/rootfs-version"]) : nil;
}

- (NSString *)pendingRollback {
    return [NSUserDefaults.standardUserDefaults stringForKey:kPendingRollback];
}
- (void)setPendingRollback:(NSString *)pendingRollback {
    [NSUserDefaults.standardUserDefaults setObject:pendingRollback forKey:kPendingRollback];
}

- (BOOL)rollBackDefaultRootWithProgress:(id<ProgressReporter>)progress error:(NSError **)error {
    NSString *name = self.defaultRoot;
    NSString *previousName = self.pendingRollback ?: self.previousRootName;
    if (name == nil || previousName == nil || ![self.roots containsObject:previousName]) {
        *error = [NSError errorWithDomain:@"iSH" code:ENOENT userInfo:@{NSLocalizedDescriptionKey: @"There is no earlier system to roll back to"}];
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *current = [self rootUrl:name];
    NSURL *previous = [self rootUrl:previousName];
    [fm createDirectoryAtURL:StagingDir() withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *staged = [StagingDir() URLByAppendingPathComponent:[@"rollback-" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];
    [progress updateProgress:0 message:@"Restoring the earlier system…"];
    // An APFS clone: instant, and the kept root stays untouched until the swap.
    if (![fm copyItemAtURL:previous toURL:staged error:error])
        return NO;
    [progress updateProgress:0.5 message:@"Keeping your files…"];
    NSString *message = nil;
    if (!CarryUserData(current, staged, UpdateKeptPaths(), &message)) {
        *error = [NSError errorWithDomain:@"iSH" code:EIO userInfo:@{NSLocalizedDescriptionKey: message ?: @"could not keep user data"}];
        [fm removeItemAtURL:staged error:nil];
        return NO;
    }
    ListPackagesToReinstall(current, staged);

    NSString *newer = [NSString stringWithFormat:@"%@ (rolled back from %@)", name, self.installedRootVersion ?: @"unversioned"];
    while ([self.roots containsObject:newer] || [fm fileExistsAtPath:[self rootUrl:newer].path])
        newer = [newer stringByAppendingString:@"+"];
    if (![fm moveItemAtURL:current toURL:[self rootUrl:newer] error:error]) {
        [fm removeItemAtURL:staged error:nil];
        return NO;
    }
    if (![fm moveItemAtURL:staged toURL:current error:error]) {
        [fm moveItemAtURL:[self rootUrl:newer] toURL:current error:nil];
        [fm removeItemAtURL:staged error:nil];
        return NO;
    }
    // The default root is now that system; its kept copy is no longer needed.
    void (^updateRoots)(void) = ^{
        NSMutableOrderedSet *roots = [self mutableOrderedSetValueForKey:@"roots"];
        [roots addObject:newer];
        [roots removeObject:previousName];
    };
    if (!NSThread.isMainThread)
        dispatch_sync(dispatch_get_main_queue(), updateRoots);
    else
        updateRoots();
    DeleteInBackground(previous);
    return YES;
}

#pragma mark - Factory reset

- (NSString *)pendingFactoryReset {
    return [NSUserDefaults.standardUserDefaults stringForKey:kPendingFactoryReset];
}
- (void)setPendingFactoryReset:(NSString *)pendingFactoryReset {
    [NSUserDefaults.standardUserDefaults setObject:pendingFactoryReset forKey:kPendingFactoryReset];
}

/// "Keep my files": the user's directories, plus the mount points of the iPad folders
/// (Files › Add iPad Folder…) outside them, so iOSFS can mount those folders again.
static NSArray<NSString *> *FactoryResetKeptPaths(void) {
    NSMutableArray<NSString *> *kept = [@[@"/root", @"/home"] mutableCopy];
    NSDictionary *mounts = [NSUserDefaults.standardUserDefaults dictionaryForKey:kMountBookmarks];
    for (NSString *point in mounts) {
        if (![point isKindOfClass:NSString.class] || ![point hasPrefix:@"/"])
            continue;
        BOOL inside = NO;
        for (NSString *path in @[@"/root", @"/home"])
            inside = inside || [point isEqualToString:path] || [point hasPrefix:[path stringByAppendingString:@"/"]];
        if (!inside)
            [kept addObject:point];
    }
    return kept;
}

- (BOOL)resetDefaultRootKeepingFiles:(BOOL)keepFiles progress:(id<ProgressReporter>)progress error:(NSError **)error {
    NSURL *archive = self.updateRootArchive;
    BOOL fromDownload = self.prefersDownloadedRoot;
    if (archive == nil) {
        *error = [NSError errorWithDomain:@"iSH" code:ENOENT userInfo:@{NSLocalizedDescriptionKey: @"The app has no Linux system to reset to"}];
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (self.needsDefaultRoot) {
        if (![self importRootFromArchive:archive name:@"default" error:error progressReporter:progress])
            return NO;
    } else {
        NSString *name = self.defaultRoot;
        NSURL *old = [self rootUrl:name];
        [fm createDirectoryAtURL:StagingDir() withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *staged = [StagingDir() URLByAppendingPathComponent:[@"reset-" stringByAppendingString:NSProcessInfo.processInfo.globallyUniqueString]];
        struct fakefsify_error fs_err;
        if (!fakefs_import(archive.fileSystemRepresentation, staged.fileSystemRepresentation, &fs_err,
                           (struct progress) {(__bridge void *) progress, root_progress_callback})) {
            *error = [NSError errorWithDomain:fs_err.type == ERR_SQLITE ? @"SQLite" : NSPOSIXErrorDomain code:fs_err.code
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%s, line %d", fs_err.message, fs_err.line]}];
            free(fs_err.message);
            [fm removeItemAtURL:staged error:nil];
            return NO;
        }
        if (keepFiles) {
            [progress updateProgress:1 message:@"Keeping your files…"];
            NSString *message = nil;
            if (!CarryUserData(old, staged, FactoryResetKeptPaths(), &message)) {
                *error = [NSError errorWithDomain:@"iSH" code:EIO userInfo:@{NSLocalizedDescriptionKey: message ?: @"could not keep your files"}];
                [fm removeItemAtURL:staged error:nil];
                return NO;
            }
        }
        // Swap. Until the second move completes, the next launch puts the old root back.
        NSURL *trash = [RootsDir() URLByAppendingPathComponent:[kResetTrashPrefix stringByAppendingString:name]];
        [fm removeItemAtURL:trash error:nil];
        if (![fm moveItemAtURL:old toURL:trash error:error]) {
            [fm removeItemAtURL:staged error:nil];
            return NO;
        }
        if (![fm moveItemAtURL:staged toURL:old error:error]) {
            [fm moveItemAtURL:trash toURL:old error:nil];
            [fm removeItemAtURL:staged error:nil];
            return NO;
        }
        DeleteInBackground(trash);
    }
    if (!keepFiles)
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kMountBookmarks];
    if (fromDownload)
        [fm removeItemAtURL:DownloadedRootDir() error:nil];
    self.pendingUpdate = nil;
    return YES;
}

+ (instancetype)instance {
    static Roots *instance;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        instance = [Roots new];
    });
    return instance;
}

@end
