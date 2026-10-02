//
//  Roots.h
//  iSH
//
//  Created by Theodore Dubois on 6/7/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ProgressReporter

- (void)updateProgress:(double)progressFraction message:(NSString *)progressMessage;
- (BOOL)shouldCancel;

@end

@interface Roots : NSObject

+ (instancetype)instance;

@property (readonly) NSOrderedSet<NSString *> *roots;
@property NSString *defaultRoot;
@property (readonly) BOOL wantsVersionFile;
- (NSURL *)rootUrl:(NSString *)name;
- (BOOL)importRootFromArchive:(NSURL *)archive name:(NSString *)name error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress;
- (BOOL)exportRootNamed:(NSString *)name toArchive:(NSURL *)archive error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress;
- (BOOL)destroyRootNamed:(NSString *)name error:(NSError **)error;
- (BOOL)renameRoot:(NSString *)name toName:(NSString *)newName error:(NSError **)error;

/// The bundled rootfs (root.tar.gz in the app bundle), and the version stamp the release
/// build writes next to it (root.version) and into it (/usr/share/ish/rootfs-version).
@property (readonly, nullable) NSURL *bundledRootArchive;
@property (readonly, nullable) NSString *bundledRootVersion;
/// The version stamp of the default root, or nil for roots made before stamps existed.
@property (readonly, nullable) NSString *installedRootVersion;
/// Where the default root lives (or will live, before the first import).
@property (readonly) NSURL *defaultRootUrl;
/// True when no root exists yet, so the bundled one must be imported before booting.
@property (readonly) BOOL needsDefaultRoot;
/// Imports the bundled rootfs as the default root. Safe to interrupt: the import goes to
/// a staging directory that is only moved into place when complete, and stale staging
/// directories are removed at the next launch.
- (BOOL)importBundledRootWithProgress:(id<ProgressReporter> _Nullable)progress error:(NSError **)error;

/// A bundled rootfs newer than the default root's, or nil.
@property (readonly, nullable) NSString *availableUpdate;
/// Set by "Update Linux system": the update is installed before the next boot.
@property (nullable) NSString *pendingUpdate;
/// Replaces the default root's system with the bundled rootfs, keeping user data: /root,
/// /home, /opt, /srv, the account files in /etc and the onboarding choices are carried
/// over; packages the user added are listed in /etc/ish/reinstall-packages for the guest
/// to reinstall. The previous root is kept (renamed) until the user deletes it.
- (BOOL)updateDefaultRootWithProgress:(id<ProgressReporter> _Nullable)progress error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
