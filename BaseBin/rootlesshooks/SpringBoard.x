#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/objc.h>
#import <libroot.h>
#import <fcntl.h>

bool string_has_prefix(const char *str, const char* prefix) {
	if (!str || !prefix) return false;
	return strncmp(str, prefix, strlen(prefix)) == 0;
}

@interface XBSnapshotContainerIdentity : NSObject <NSCopying>
@property (nonatomic, readonly, copy) NSString* bundleIdentifier;
- (NSString*)snapshotContainerPath;
@end

%hook XBSnapshotContainerIdentity

- (NSString *)snapshotContainerPath {
	NSString *path = %orig;
	if ([path hasPrefix:@"/var/mobile/Library/SplashBoard/Snapshots/"] && ![self.bundleIdentifier hasPrefix:@"com.apple."]) {
		return JBROOT_PATH_NSSTRING(path);
	}
	return path;
}

%end

%hookf(int, fcntl, int fildes, int cmd, ...) {
	if (cmd == F_SETPROTECTIONCLASS) {
		char filePath[PATH_MAX];
		if (fcntl(fildes, F_GETPATH, filePath) != -1 && string_has_prefix(filePath, JBROOT_PATH_CSTRING("/var/mobile/Library/SplashBoard/Snapshots"))) {
			return 0;
		}
	}
	
	va_list a;
	va_start(a, cmd);
	int result = %orig(fildes, cmd, va_arg(a, void *), va_arg(a, void *), va_arg(a, void *), va_arg(a, void *), va_arg(a, void *), va_arg(a, void *), va_arg(a, void *), va_arg(a, void *), va_arg(a, void *));
	va_end(a);
	return result;
}

void springboardInit(void) {
	%init();
}
