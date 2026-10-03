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

/// A Linux system downloaded from a GitHub release (Settings › Updates), kept until it is
/// installed or the app bundles one at least as new.
@property (readonly, nullable) NSURL *downloadedRootArchive;
@property (readonly, nullable) NSString *downloadedRootVersion;
/// Moves a verified rootfs tarball in as the downloaded system, replacing an earlier one.
- (BOOL)storeDownloadedRootArchive:(NSURL *)archive version:(NSString *)version error:(NSError **)error;
/// What an update installs: the downloaded system when it is newer than the bundled one,
/// else the bundled one.
@property (readonly, nullable) NSURL *updateRootArchive;
@property (readonly, nullable) NSString *updateRootVersion;

/// An update source (updateRootVersion) newer than the default root's, or nil.
@property (readonly, nullable) NSString *availableUpdate;
/// Set by "Update Linux system": the update is installed before the next boot.
@property (nullable) NSString *pendingUpdate;
/// Replaces the default root's system with updateRootArchive, keeping user data: /root,
/// /home, /opt, /srv, the account files in /etc and the onboarding choices are carried
/// over; packages the user added are listed in /etc/ish/reinstall-packages for the guest
/// to reinstall. The previous root is kept (renamed) until the user deletes it.
- (BOOL)updateDefaultRootWithProgress:(id<ProgressReporter> _Nullable)progress error:(NSError **)error;

/// The system an update replaced, kept as "<default> (before update <version>)": the newest
/// such root, or nil when there is none.
@property (readonly, nullable) NSString *previousRootName;
/// The rootfs version of previousRootName, or nil.
@property (readonly, nullable) NSString *previousRootVersion;
/// Set by Settings › Updates › Roll Back: the root name to roll back to before the next boot.
@property (nullable) NSString *pendingRollback;
/// Makes previousRootName the default root again, carrying the same user data as an update
/// (/root, /home, /opt, /srv, accounts, onboarding and ishwl options) over from the current
/// one, which is kept as "<default> (rolled back from <version>)". The previous root is
/// cloned into staging first, so an interrupted rollback leaves both systems as they were.
- (BOOL)rollBackDefaultRootWithProgress:(id<ProgressReporter> _Nullable)progress error:(NSError **)error;

/// Set by Settings › Maintenance › Reset to Factory (or the Settings app): RootsFactoryResetKeepFiles
/// or RootsFactoryResetErase. The reset runs before the next boot.
@property (nullable) NSString *pendingFactoryReset;
/// Replaces the default root with a fresh copy of updateRootArchive (the newest system the
/// app has). With keepFiles, /root, /home and the iPad folder mount points are carried
/// over and the iPad folder list is kept; without, the iPad folder list is forgotten too
/// (the folders' files stay on the iPad). Safe to interrupt: the new root is imported into
/// staging, and the old one is only moved aside (and deleted) once the new one is complete;
/// a launch after an interruption between the two moves puts the old root back.
- (BOOL)resetDefaultRootKeepingFiles:(BOOL)keepFiles progress:(id<ProgressReporter> _Nullable)progress error:(NSError **)error;

@end

extern NSString *const RootsFactoryResetKeepFiles; ///< @"keep-files"
extern NSString *const RootsFactoryResetErase;     ///< @"erase"

NS_ASSUME_NONNULL_END
