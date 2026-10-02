//
//  iOSFS.h
//  iSH
//
//  Created by Noah Peeters on 26.10.19.
//

extern const struct fs_ops iosfs;
extern const struct fs_ops iosfs_unsafe;

void iosfs_init(void);
void iosfs_clear_all_bookmarks(void); // for recovery

#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Mounting a folder the user picked (desktop Files: "Add iPad Folder…"). The folder's
// security-scoped bookmark joins the ones `mount -t ios` keeps, so iosfs_init mounts it
// again at boot. Call on the main thread; returns 0 or a negative Linux errno.
int iosfs_mount_url(NSURL *_Nonnull url, NSString *_Nonnull point);
int iosfs_unmount_point(NSString *_Nonnull point);
// Mount point → bookmark of every remembered iOS folder mount.
NSDictionary<NSString *, NSData *> *_Nonnull iosfs_mount_bookmarks(void);
#endif
