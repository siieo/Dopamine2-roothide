//
//  Bootstrapper.m
//  Dopamine
//
//  Created by Lars Fröder on 09.01.24.
//

#import "DOBootstrapper.h"
#import "DOEnvironmentManager.h"
#import "DOUIManager.h"
#import <libjailbreak/info.h>
#import <libjailbreak/util.h>
#import <libjailbreak/jbclient_xpc.h>
#import "zstd.h"
#import <sys/mount.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import "NSString+Version.h"

#define LIBKRW_DOPAMINE_BUNDLED_VERSION @"2.0.3"
#define LIBROOT_DOPAMINE_BUNDLED_VERSION @"1.0.1"
#define BASEBIN_LINK_BUNDLED_VERSION @"1.0.0"

static NSDictionary *gBundledPackages = @{
	@"libkrw0-dopamine" : LIBKRW_DOPAMINE_BUNDLED_VERSION,
	@"libroot-dopamine" : LIBROOT_DOPAMINE_BUNDLED_VERSION,
	@"dopamine-basebin-link" : BASEBIN_LINK_BUNDLED_VERSION,
};

struct hfs_mount_args {
	char	*fspec;
	uid_t	hfs_uid;	/* uid that owns hfs files (standard HFS only) */
	gid_t	hfs_gid;	/* gid that owns hfs files (standard HFS only) */
	mode_t	hfs_mask;	/* mask to be applied for hfs perms  (standard HFS only) */
	uint32_t hfs_encoding;	/* encoding for this volume (standard HFS only) */
	struct	timezone hfs_timezone;	/* user time zone info (standard HFS only) */
	int	flags;		/* mounting flags, see below */
	int	 journal_tbuffer_size;   /* size in bytes of the journal transaction buffer */
	int	journal_flags;	  /* flags to pass to journal_open/create */
	int	journal_disable;	/* don't use journaling (potentially dangerous) */
};

NSString *const bootstrapErrorDomain = @"BootstrapErrorDomain";
typedef NS_ENUM(NSInteger, JBErrorCode) {
	BootstrapErrorCodeFailedToGetURL		= -1,
	BootstrapErrorCodeFailedToDownload	  = -2,
	BootstrapErrorCodeFailedDecompressing	   = -3,
	BootstrapErrorCodeFailedExtracting	  = -4,
	BootstrapErrorCodeFailedRemount		 = -5,
	BootstrapErrorCodeFailedFinalising	  = -6,
	BootstrapErrorCodeFailedReplacing	   = -7,
};

#define BUFFER_SIZE 8192

@implementation DOBootstrapper

- (instancetype)init
{
	self = [super init];
	if (self) {
	}
	return self;
}

- (NSError *)decompressZstd:(NSString *)zstdPath toTar:(NSString *)tarPath
{
	// Helper method to cleanup resources on error
	void (^cleanup)(FILE *, FILE *, ZSTD_DCtx *, ZSTD_DStream *, uint8_t *, uint8_t *) = ^(FILE *input_file, FILE *output_file, ZSTD_DCtx *dctx, ZSTD_DStream *dstream, uint8_t *input_buffer, uint8_t *output_buffer) {
		if (input_file) fclose(input_file);
		if (output_file) fclose(output_file);
		if (dctx) ZSTD_freeDCtx(dctx);
		if (dstream) ZSTD_freeDStream(dstream);
		if (input_buffer) free(input_buffer);
		if (output_buffer) free(output_buffer);
	};

	// Open the input and output files
	FILE *input_file = fopen(zstdPath.fileSystemRepresentation, "rb");
	if (!input_file) {
		return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to open input file %@: %s", zstdPath, strerror(errno)]}];
	}

	FILE *output_file = fopen(tarPath.fileSystemRepresentation, "wb");
	if (!output_file) {
		cleanup(input_file, NULL, NULL, NULL, NULL, NULL);
		return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to open output file %@: %s", tarPath, strerror(errno)]}];
	}

	// Create ZSTD decompression context and buffers
	ZSTD_DCtx *dctx = ZSTD_createDCtx();
	ZSTD_DStream *dstream = ZSTD_createDStream();
	uint8_t *input_buffer = malloc(BUFFER_SIZE);
	uint8_t *output_buffer = malloc(BUFFER_SIZE);

	if (!dctx || !dstream || !input_buffer || !output_buffer) {
		cleanup(input_file, output_file, dctx, dstream, input_buffer, output_buffer);
		return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : @"Failed to allocate memory or create decompression context"}];
	}

	// Initialize the decompression stream
	size_t ret = ZSTD_initDStream(dstream);
	if (ZSTD_isError(ret)) {
		cleanup(input_file, output_file, dctx, dstream, input_buffer, output_buffer);
		return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to initialize decompression stream: %s", ZSTD_getErrorName(ret)]}];
	}

	// Read and decompress data
	size_t total_bytes_written = 0;
	ZSTD_inBuffer in = {0};
	ZSTD_outBuffer out = {0};
	out.dst = output_buffer;
	out.size = BUFFER_SIZE;

	while (1) {
		// Read data into input buffer
		in.size = fread(input_buffer, 1, BUFFER_SIZE, input_file);
		if (in.size == 0) break;
		
		in.src = input_buffer;
		in.pos = 0;

		while (in.pos < in.size) {
			out.pos = 0;
			ret = ZSTD_decompressStream(dstream, &out, &in);
			if (ZSTD_isError(ret)) {
				cleanup(input_file, output_file, dctx, dstream, input_buffer, output_buffer);
				return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Decompression failed: %s", ZSTD_getErrorName(ret)]}];
			}

			// Write decompressed data
			size_t bytes_written = fwrite(output_buffer, 1, out.pos, output_file);
			if (bytes_written != out.pos) {
				cleanup(input_file, output_file, dctx, dstream, input_buffer, output_buffer);
				return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedDecompressing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to write output file: %s", strerror(errno)]}];
			}

			total_bytes_written += bytes_written;
		}
	}

	// Cleanup and return success
	cleanup(input_file, output_file, dctx, dstream, input_buffer, output_buffer);
	return nil;
}


- (NSError *)extractTar:(NSString *)tarPath toPath:(NSString *)destinationPath
{
	int r = libarchive_unarchive(tarPath.fileSystemRepresentation, destinationPath.fileSystemRepresentation);
	if (r != 0) {
	return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"libarchive returned %d", r]}];
	}
	return nil;
}

- (BOOL)deleteSymlinkAtPath:(NSString *)path error:(NSError **)error
{
	NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:error];
	if (!attributes) return YES;
	if (attributes[NSFileType] == NSFileTypeSymbolicLink) {
	return [[NSFileManager defaultManager] removeItemAtPath:path error:error];
	}
	return NO;
}

- (BOOL)fileOrSymlinkExistsAtPath:(NSString *)path
{
	if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
	
	NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
	if (attributes) {
	if (attributes[NSFileType] == NSFileTypeSymbolicLink) {
		return YES;
	}
	}
	
	return NO;
}

- (NSError *)createSymlinkAtPath:(NSString *)path toPath:(NSString *)destinationPath createIntermediateDirectories:(BOOL)createIntermediate
{
	NSError *error;
	NSString *parentPath = [path stringByDeletingLastPathComponent];
	if (![[NSFileManager defaultManager] fileExistsAtPath:parentPath]) {
	if (!createIntermediate) return [NSError errorWithDomain:bootstrapErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed create %@->%@ symlink: Parent dir does not exists", path, destinationPath]}];
	if (![[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:&error]) return error;
	}
	
	[[NSFileManager defaultManager] createSymbolicLinkAtPath:path withDestinationPath:destinationPath error:&error];
	return error;
}

- (void)patchBasebinDaemonPlist:(NSString *)plistPath
{
	NSMutableDictionary *plistDict = [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
	if (plistDict) {
	bool madeChanges = NO;
	NSMutableArray *programArguments = ((NSArray *)plistDict[@"ProgramArguments"]).mutableCopy;
	for (NSString *argument in [programArguments reverseObjectEnumerator]) {
		if ([argument containsString:@"@JBROOT@"]) {
		programArguments[[programArguments indexOfObject:argument]] = [argument stringByReplacingOccurrencesOfString:@"@JBROOT@" withString:JBROOT_PATH(@"/")];
		madeChanges = YES;
		}
	}
	if (madeChanges) {
		plistDict[@"ProgramArguments"] = programArguments.copy;
		[plistDict writeToFile:plistPath atomically:NO];
	}
	}
}

- (void)patchBasebinDaemonPlists
{
	NSURL *basebinDaemonsURL = [NSURL fileURLWithPath:JBROOT_PATH(@"/basebin/LaunchDaemons")];
	for (NSURL *basebinDaemonURL in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:basebinDaemonsURL includingPropertiesForKeys:nil options:0 error:nil]) {
	[self patchBasebinDaemonPlist:basebinDaemonURL.path];
	}
}

- (NSString *)bootstrapVersion
{
	uint64_t cfver = (((uint64_t)kCFCoreFoundationVersionNumber / 100) * 100);
	if (cfver >= 2000) {
	return nil;
	}
	return [NSString stringWithFormat:@"%llu", cfver];
}

- (NSURL *)bootstrapURL
{
	return [NSURL URLWithString:[NSString stringWithFormat:@"https://apt.procurs.us/bootstraps/%@/bootstrap-ssh-iphoneos-arm64.tar.zst", [self bootstrapVersion]]];
}

#if 0
- (void)prepareBootstrapWithCompletion:(void (^)(NSError *))completion
{
	[[DOUIManager sharedInstance] sendLog:@"Updating BaseBin" debug:NO];

	// Ensure /private/preboot is writable (iOS <= 15)
	NSError *error = [self ensurePrivatePrebootIsWritable];
	if (error) return completion(error);

	[self fixupPathPermissions];

	// Safely handle /var/jb symlink removal
	error = [self removeSymlinkAtPath:@"/var/jb"];
	if (error) return completion(error);

	// Clean up xinaA15 leftovers if necessary
	if (![self cleanupXinaA15Files]) {
		return completion([NSError errorWithDomain:bootstrapErrorDomain
											   code:BootstrapErrorCodeFailedReplacing
										   userInfo:@{NSLocalizedDescriptionKey : @"Failed to clean up xinaA15 files"}]);
	}

	// Create symlink and handle basebin extraction
	error = [self createSymlinkAtPath:@"/var/jb" toPath:JBROOT_PATH(@"/")];
	if (error) return completion(error);

	NSString *basebinPath = JBROOT_PATH(@"/basebin");
	if ([[NSFileManager defaultManager] fileExistsAtPath:basebinPath]) {
		error = [self removeItemAtPath:basebinPath];
		if (error) return completion(error);
	}

	error = [self extractTar:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"] toPath:JBROOT_PATH(@"/")];
	if (error) return completion(error);

	[self patchBasebinDaemonPlists];
	[[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/basebin/basebin.tc") error:nil];

	// Write default sources and create preferences directory
	[self writeDefaultSources];
	[self createPreferencesDirectoryIfNeeded];

	JBFixMobilePermissions();
	completion(nil);
}

- (NSError *)removeSymlinkAtPath:(NSString *)path
{
	NSError *error = nil;
	if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
		if (![self deleteSymlinkAtPath:path error:&error]) {
			return error;
		}
	}
	return nil;
}

- (BOOL)cleanupXinaA15Files
{
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/.keep_symlinks"]) return YES;

	NSArray *xinaLeftoverSymlinks = @[
		@"/var/alternatives", @"/var/ap", @"/var/apt", @"/var/bin", @"/var/bzip2", @"/var/cache", 
		@"/var/dpkg", @"/var/etc", @"/var/gzip", @"/var/lib", @"/var/Lib", @"/var/libexec", 
		@"/var/Library", @"/var/LIY", @"/var/Liy", @"/var/local", @"/var/newuser", @"/var/profile", 
		@"/var/sbin", @"/var/suid_profile", @"/var/sh", @"/var/sy", @"/var/share", @"/var/ssh", 
		@"/var/sudo_logsrvd.conf", @"/var/suid_profile", @"/var/sy", @"/var/usr", @"/var/zlogin", 
		@"/var/zlogout", @"/var/zprofile", @"/var/zshenv", @"/var/zshrc", @"/var/log/dpkg", @"/var/log/apt"
	];

	NSArray *xinaLeftoverFiles = @[
		@"/var/master.passwd"
	];

	for (NSString *symlink in xinaLeftoverSymlinks) {
		[self deleteSymlinkAtPath:symlink error:nil];
	}

	for (NSString *file in xinaLeftoverFiles) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:file]) {
			[[NSFileManager defaultManager] removeItemAtPath:file error:nil];
		}
	}

	return YES;
}

- (void)writeDefaultSources
{
	NSString *defaultSources = @"Types: deb\n"
	@"URIs: https://repo.chariz.com/\n"
	@"Suites: ./\n"
	@"Components:\n"
	@"\n"
	@"Types: deb\n"
	@"URIs: https://havoc.app/\n"
	@"Suites: ./\n"
	@"Components:\n"
	@"\n"
	@"Types: deb\n"
	@"URIs: http://apt.thebigboss.org/repofiles/cydia/\n"
	@"Suites: stable\n"
	@"Components: main\n"
	@"\n"
	@"Types: deb\n"
	@"URIs: https://ellekit.space/\n"
	@"Suites: ./\n"
	@"Components:\n";
	[defaultSources writeToFile:JBROOT_PATH(@"/etc/apt/sources.list.d/default.sources") atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

- (void)createPreferencesDirectoryIfNeeded
{
	NSString *mobilePreferencesPath = JBROOT_PATH(@"/var/mobile/Library/Preferences");
	if (![[NSFileManager defaultManager] fileExistsAtPath:mobilePreferencesPath]) {
		NSDictionary<NSFileAttributeKey, id> *attributes = @{
			NSFilePosixPermissions : @0755,
			NSFileOwnerAccountID : @501,
			NSFileGroupOwnerAccountID : @501,
		};
		[[NSFileManager defaultManager] createDirectoryAtPath:mobilePreferencesPath withIntermediateDirectories:YES attributes:attributes error:nil];
	}
}
#endif

- (int)installPackage:(NSString *)packagePath
{
	if (getuid() == 0) {
	return exec_cmd_trusted(JBROOT_PATH("/usr/bin/dpkg"), "-i", packagePath.fileSystemRepresentation, NULL);
	}
	else {
	// idk why but waitpid sometimes fails and this returns -1, so we just ignore the return value
	exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", "install_pkg", packagePath.fileSystemRepresentation, NULL);
	return 0;
	}
}

- (int)uninstallPackageWithIdentifier:(NSString *)identifier
{
	return exec_cmd_trusted(JBROOT_PATH("/usr/bin/dpkg"), "-r", identifier.UTF8String, NULL);
}

- (NSString *)installedVersionForPackageWithIdentifier:(NSString *)identifier
{
	NSString *dpkgStatus = [NSString stringWithContentsOfFile:JBROOT_PATH(@"/var/lib/dpkg/status") encoding:NSUTF8StringEncoding error:nil];
	NSString *packageStartLine = [NSString stringWithFormat:@"Package: %@", identifier];
	
	NSArray *packageInfos = [dpkgStatus componentsSeparatedByString:@"\n\n"];
	for (NSString *packageInfo in packageInfos) {
	if ([packageInfo hasPrefix:packageStartLine]) {
		__block NSString *version = nil;
		[packageInfo enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
		if ([line hasPrefix:@"Version: "]) {
			version = [line substringFromIndex:9];
		}
		}];
		return version;
	}
	}
	return nil;
}

- (NSError *)installPackageManagers
{
	NSArray *enabledPackageManagers = [[DOUIManager sharedInstance] enabledPackageManagers];
	for (NSDictionary *packageManagerDict in enabledPackageManagers) {
	NSString *path = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:packageManagerDict[@"Package"]];
	NSString *name = packageManagerDict[@"Display Name"];
	int r = [self installPackage:path];
	if (r != 0) {
		return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install %@: %d\n", name, r]}];
	}
	}
	return nil;
}

- (BOOL)shouldInstallPackage:(NSString *)identifier
{
	NSString *bundledVersion = gBundledPackages[identifier];
	if (!bundledVersion) return NO;
	
	NSString *installedVersion = [self installedVersionForPackageWithIdentifier:identifier];
	if (!installedVersion) return YES;
	
	return [installedVersion numericalVersionRepresentation] < [bundledVersion numericalVersionRepresentation];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
	if (downloadTask == _bootstrapDownloadTask) {
	NSString *sizeString = [NSByteCountFormatter stringFromByteCount:totalBytesWritten countStyle:NSByteCountFormatterCountStyleFile];
	NSString *writtenBytesString = [NSByteCountFormatter stringFromByteCount:totalBytesExpectedToWrite countStyle:NSByteCountFormatterCountStyleFile];
	
	[[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@"Downloading Bootstrap (%@/%@)", sizeString, writtenBytesString] debug:NO update:YES];
	}
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
	_downloadCompletionBlock(nil, error);
}

- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location
{
	_downloadCompletionBlock(location, nil);
}

@end

@implementation DOBootstrapper(roothide)

uint64_t jbrand_new()
{
	uint64_t value = ((uint64_t)arc4random()) | ((uint64_t)arc4random())<<32;
	uint8_t check = value>>8 ^ value >> 16 ^ value>>24 ^ value>>32 ^ value>>40 ^ value>>48 ^ value>>56;
	return (value & ~0xFF) | check;
}

int is_jbrand_value(uint64_t value)
{
   uint8_t check = value>>8 ^ value >> 16 ^ value>>24 ^ value>>32 ^ value>>40 ^ value>>48 ^ value>>56;
   return check == (uint8_t)value;
}

#define JB_ROOT_PREFIX ".jbroot-"
#define JB_RAND_LENGTH  (sizeof(uint64_t)*sizeof(char)*2)

int is_jbroot_name(const char* name)
{
	if(strlen(name) != (sizeof(JB_ROOT_PREFIX)-1+JB_RAND_LENGTH))
	return 0;
	
	if(strncmp(name, JB_ROOT_PREFIX, sizeof(JB_ROOT_PREFIX)-1) != 0)
	return 0;
	
	char* endp=NULL;
	uint64_t value = strtoull(name+sizeof(JB_ROOT_PREFIX)-1, &endp, 16);
	if(!endp || *endp!='\0')
	return 0;
	
	if(!is_jbrand_value(value))
	return 0;
	
	return 1;
}

uint64_t resolve_jbrand_value(const char* name)
{
	if(strlen(name) != (sizeof(JB_ROOT_PREFIX)-1+JB_RAND_LENGTH))
	return 0;
	
	if(strncmp(name, JB_ROOT_PREFIX, sizeof(JB_ROOT_PREFIX)-1) != 0)
	return 0;
	
	char* endp=NULL;
	uint64_t value = strtoull(name+sizeof(JB_ROOT_PREFIX)-1, &endp, 16);
	if(!endp || *endp!='\0')
	return 0;
	
	if(!is_jbrand_value(value))
	return 0;
	
	return value;
}

NSString* find_jbroot(BOOL force)
{
	static NSString* cached_jbroot = nil;
	if(!force && cached_jbroot) {
	return cached_jbroot;
	}
	@synchronized(@"find_jbroot_lock")
	{
	//jbroot path may change when re-randomize it
	NSString * jbroot = nil;
	NSArray *subItems = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application/" error:nil];
	for (NSString *subItem in subItems) {
		if (is_jbroot_name(subItem.UTF8String))
		{
		NSString* path = [@"/var/containers/Bundle/Application/" stringByAppendingPathComponent:subItem];
		jbroot = path;
		break;
		}
	}
	cached_jbroot = jbroot;
	}
	return cached_jbroot;
}

NSString *jbroot(NSString *path)
{
	NSString* jbroot = find_jbroot(NO);
	assert(jbroot != NULL); //to avoid [nil stringByAppendingString:
	return [jbroot stringByAppendingPathComponent:path];
}

uint64_t jbrand()
{
	NSString* jbroot = find_jbroot(NO);
	assert(jbroot != NULL);
	return resolve_jbrand_value([jbroot lastPathComponent].UTF8String);
}

NSString* rootfsPrefix(NSString* path)
{
	return [@"/rootfs/" stringByAppendingPathComponent:path];
}

#define DOPAMINE_INSTALL_VERSION	2
#define STRAPLOG(...)   [[DOUIManager sharedInstance] sendLog:[NSString stringWithFormat:@__VA_ARGS__] debug:YES];
#define ASSERT(...)	 do{if(!(__VA_ARGS__)) {completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"ABORT: %s (%d): %s", __FILE_NAME__, __LINE__, #__VA_ARGS__]}]);return -1;}} while(0)

#define DEFAULT_SOURCES "\
Types: deb\n\
URIs: https://repo.chariz.com/\n\
Suites: ./\n\
Components:\n\
\n\
Types: deb\n\
URIs: https://havoc.app/\n\
Suites: ./\n\
Components:\n\
\n\
Types: deb\n\
URIs: http://apt.thebigboss.org/repofiles/cydia/\n\
Suites: stable\n\
Components: main\n\
\n\
Types: deb\n\
URIs: https://roothide.github.io/\n\
Suites: ./\n\
Components:\n\
\n\
Types: deb\n\
URIs: https://roothide.github.io/procursus\n\
Suites: iphoneos-arm64e/%d\n\
Components: main\n\
"

#define ALT_SOURCES "\
Types: deb\n\
URIs: https://iosjb.top/\n\
Suites: ./\n\
Components:\n\
\n\
Types: deb\n\
URIs: https://iosjb.top/procursus\n\
Suites: iphoneos-arm64e/%d\n\
Components: main\n\
"

#define ZEBRA_SOURCES "\
# Zebra Sources List\n\
deb https://getzbra.com/repo/ ./\n\
deb https://repo.chariz.com/ ./\n\
deb https://yourepo.com/ ./\n\
deb https://havoc.app/ ./\n\
deb https://roothide.github.io/ ./\n\
deb https://roothide.github.io/procursus iphoneos-arm64e/%d main\n\
\n\
"

int getCFMajorVersion(void)
{
	return ((int)kCFCoreFoundationVersionNumber / 100) * 100;
}

-(int) buildPackageSources:(void (^)(NSError *))completion
{
	NSFileManager* fm = NSFileManager.defaultManager;
	
	ASSERT([[NSString stringWithFormat:@(DEFAULT_SOURCES), getCFMajorVersion()] writeToFile:jbroot(@"/etc/apt/sources.list.d/default.sources") atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	
	//Users in some regions seem to be unable to access github.io
	if([NSLocale.currentLocale.countryCode isEqualToString:@"CN"]) {
	ASSERT([[NSString stringWithFormat:@(ALT_SOURCES), getCFMajorVersion()] writeToFile:jbroot(@"/etc/apt/sources.list.d/sileo.sources") atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	}
	
	if(![fm fileExistsAtPath:jbroot(@"/var/mobile/Library/Application Support/xyz.willy.Zebra")])
	{
	NSDictionary* attr = @{NSFilePosixPermissions:@(0755), NSFileOwnerAccountID:@(501), NSFileGroupOwnerAccountID:@(501)};
	ASSERT([fm createDirectoryAtPath:jbroot(@"/var/mobile/Library/Application Support/xyz.willy.Zebra") withIntermediateDirectories:YES attributes:attr error:nil]);
	}
	
	ASSERT([[NSString stringWithFormat:@(ZEBRA_SOURCES), getCFMajorVersion()] writeToFile:jbroot(@"/var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list") atomically:YES encoding:NSUTF8StringEncoding error:nil]);
	
	return 0;
}

-(int) InstallBootstrap:(NSString*)installPath WithCompletion:(void (^)(NSError *))completion
{
	[[DOUIManager sharedInstance] sendLog:@"Extracting Bootstrap" debug:NO];

	NSFileManager* fm = NSFileManager.defaultManager;
	
	NSString* jbroot_path = installPath;
	
	ASSERT(mkdir(jbroot_path.fileSystemRepresentation, 0755) == 0);
	ASSERT(chown(jbroot_path.fileSystemRepresentation, 0, 0) == 0);

	find_jbroot(YES); //refresh
	
	//jbroot() and jbrand() available now
	
	NSString* bootstrapZstFile = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
				  [NSString stringWithFormat:@"bootstrap_%d.tar.zst", getCFMajorVersion()]];

	ASSERT([fm fileExistsAtPath:bootstrapZstFile]);
	
	NSString* bootstrapTarFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bootstrap.tar"];
	if([fm fileExistsAtPath:bootstrapTarFile])
	ASSERT([fm removeItemAtPath:bootstrapTarFile error:nil]);
	
	NSError* error = [self decompressZstd:bootstrapZstFile toTar:bootstrapTarFile];
	if(error) {
	completion(error);
	return -1;
	}
	
	NSError* decompressionError = [self extractTar:bootstrapTarFile toPath:jbroot_path];
	if (decompressionError) {
	completion(decompressionError);
	return -1;
	}
	
	NSString* jbroot_secondary = [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/.jbroot-%016llX", jbrand()];
	ASSERT(mkdir(jbroot_secondary.fileSystemRepresentation, 0755) == 0);
	ASSERT(chown(jbroot_secondary.fileSystemRepresentation, 0, 0) == 0);
	
	ASSERT([fm moveItemAtPath:jbroot(@"/var") toPath:[jbroot_secondary stringByAppendingPathComponent:@"/var"] error:nil]);
	ASSERT([fm createSymbolicLinkAtPath:jbroot(@"/var") withDestinationPath:@"private/var" error:nil]);
	
	ASSERT([fm removeItemAtPath:jbroot(@"/private/var") error:nil]);
	ASSERT([fm createSymbolicLinkAtPath:jbroot(@"/private/var") withDestinationPath:[jbroot_secondary stringByAppendingPathComponent:@"/var"] error:nil]);
	
	ASSERT([fm removeItemAtPath:[jbroot_secondary stringByAppendingPathComponent:@"/var/tmp"] error:nil]);
	ASSERT([fm moveItemAtPath:jbroot(@"/tmp") toPath:[jbroot_secondary stringByAppendingPathComponent:@"/var/tmp"] error:nil]);
	ASSERT([fm createSymbolicLinkAtPath:jbroot(@"/tmp") withDestinationPath:@"var/tmp" error:nil]);
	
	for(NSString* item in [fm contentsOfDirectoryAtPath:jbroot_path error:nil])
	{
	if([item isEqualToString:@"var"])
		continue;

	ASSERT([fm createSymbolicLinkAtPath:[jbroot_secondary stringByAppendingPathComponent:item] withDestinationPath:[jbroot_path stringByAppendingPathComponent:item] error:nil]);
	}
	
	ASSERT([fm removeItemAtPath:[jbroot_secondary stringByAppendingPathComponent:@".jbroot"] error:nil]);
	ASSERT([fm createSymbolicLinkAtPath:[jbroot_secondary stringByAppendingPathComponent:@".jbroot"]
			withDestinationPath:jbroot_path error:nil]);

	if(![fm fileExistsAtPath:jbroot(@"/var/mobile/Library/Preferences")])
	{
	NSDictionary* attr = @{NSFilePosixPermissions:@(0755), NSFileOwnerAccountID:@(501), NSFileGroupOwnerAccountID:@(501)};
	ASSERT([fm createDirectoryAtPath:jbroot(@"/var/mobile/Library/Preferences") withIntermediateDirectories:YES attributes:attr error:nil]);
	}
	
	ASSERT([self buildPackageSources:completion] == 0);
	
	STRAPLOG("Status: Bootstrap Installed");
	
	return 0;
}

-(int) ReRandomizeBootstrap:(void (^)(NSError *))completion
{
	[[DOUIManager sharedInstance] sendLog:@"ReRandomizing Bootstrap" debug:NO];
	
	uint64_t prev_jbrand = jbrand();
	uint64_t new_jbrand = jbrand_new();

	//jbroot() and jbrand() unavailable
	
	NSFileManager* fm = NSFileManager.defaultManager;
	
	ASSERT( [fm moveItemAtPath:[NSString stringWithFormat:@"/var/containers/Bundle/Application/.jbroot-%016llX", prev_jbrand]
			toPath:[NSString stringWithFormat:@"/var/containers/Bundle/Application/.jbroot-%016llX", new_jbrand] error:nil] );
	
	ASSERT([fm moveItemAtPath:[NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/.jbroot-%016llX", prev_jbrand]
			   toPath:[NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/.jbroot-%016llX", new_jbrand] error:nil]);
	
	
	NSString* jbroot_path = [NSString stringWithFormat:@"/var/containers/Bundle/Application/.jbroot-%016llX", new_jbrand];
	NSString* jbroot_secondary = [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/.jbroot-%016llX", new_jbrand];

	for(NSString* item in [fm contentsOfDirectoryAtPath:jbroot_path error:nil])
	{
	if([item isEqualToString:@"var"])
		continue;

	NSString* checkpath = [jbroot_secondary stringByAppendingPathComponent:item];
	
	struct stat st;
	if(lstat(checkpath.fileSystemRepresentation, &st)==0) {
		ASSERT([fm removeItemAtPath:checkpath error:nil]);
	}
	
	ASSERT([fm createSymbolicLinkAtPath:checkpath withDestinationPath:[jbroot_path stringByAppendingPathComponent:item] error:nil]);
	}
	
	ASSERT([fm removeItemAtPath:[jbroot_path stringByAppendingPathComponent:@"/private/var"] error:nil]);
	ASSERT([fm createSymbolicLinkAtPath:[jbroot_path stringByAppendingPathComponent:@"/private/var"]
			withDestinationPath:[jbroot_secondary stringByAppendingPathComponent:@"/var"] error:nil]);
	
	ASSERT([fm removeItemAtPath:[jbroot_secondary stringByAppendingPathComponent:@".jbroot"] error:nil]);
	ASSERT([fm createSymbolicLinkAtPath:[jbroot_secondary stringByAppendingPathComponent:@".jbroot"]
			withDestinationPath:jbroot_path error:nil]);
	
	find_jbroot(YES); //refresh
	
	//jbroot() and jbrand() available now

	return 0;
}

-(int) doBootstrap:(void (^)(NSError *))completion {
	
	NSFileManager* fm = NSFileManager.defaultManager;
	
	int count=0;
	NSArray *subItems = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application/" error:nil];
	for (NSString *subItem in subItems) {
	if (is_jbroot_name(subItem.UTF8String))
		count++;
	}

	if(count > 1) {
	completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : @"\n\nThere are multi jbroot in /var/containers/Bundle/Applicaton/\n\n\n"}]);
	return -1;
	}
	
	NSString* jbroot_path = find_jbroot(YES);
	
	if(!jbroot_path) {
	STRAPLOG("device is not strapped...");
	
	jbroot_path = [NSString stringWithFormat:@"/var/containers/Bundle/Application/.jbroot-%016llX", jbrand_new()];
	
	STRAPLOG("bootstrap @ %@", jbroot_path);
	
	ASSERT([self InstallBootstrap:jbroot_path WithCompletion:completion] == 0);
	
	} else if([fm fileExistsAtPath:jbroot(@"/.bootstrapped")] || [fm fileExistsAtPath:jbroot(@"/.thebootstrapped")]) {
	
		completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : @"\n\nYour device has been bootstrapped through the Bootstrap app, please disable tweak for apps in AppList and UnBootstrap before jailbreaking.\n\n\n"}]);
		return -1;
	
	} else if(![fm fileExistsAtPath:jbroot(@"/.installed_dopamine")]) {
	
	STRAPLOG("remove unfinished bootstrap %@", jbroot_path);
	
	uint64_t prev_jbrand = jbrand();
	
	ASSERT([fm removeItemAtPath:jbroot_path error:nil]);
	
	NSString* jbroot_secondary = [NSString stringWithFormat:@"/var/mobile/Containers/Shared/AppGroup/.jbroot-%016llX", prev_jbrand];
	if([fm fileExistsAtPath:jbroot_secondary]) {
		STRAPLOG("remove unfinished bootstrap %@", jbroot_secondary);
		ASSERT([fm removeItemAtPath:jbroot_secondary error:nil]);
	}
	
	STRAPLOG("bootstrap @ %@", jbroot_path);
	
	ASSERT([self InstallBootstrap:jbroot_path WithCompletion:completion] == 0);

	} else {
	STRAPLOG("device is strapped: %@", jbroot_path);
	
	NSString* dopamineVersion = [NSString stringWithContentsOfFile:jbroot(@"/.installed_dopamine") encoding:NSUTF8StringEncoding error:nil];
	if(dopamineVersion.intValue != DOPAMINE_INSTALL_VERSION) {
		completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : @"\n\nroothide Doapmine 1 is already installed on your device.\n\n\n"}]);
		return -1;
	}
	
	STRAPLOG("Status: Rerandomize jbroot");
	
	ASSERT([self ReRandomizeBootstrap:completion] == 0);
	}
	
	STRAPLOG("Status: Bootstrap Successful");

	return 0;
}

- (void)prepareBootstrapWithCompletion:(void (^)(NSError *))completion
{

	// Remove /var/jb as it might be wrong
	NSError *error=nil;
	if (![self deleteSymlinkAtPath:@"/var/jb" error:&error]) {
	if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) {
		if (![[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:&error]) {
		completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Removing /var/jb directory failed with error: %@", error]}]);
		return;
		}
	}
	else {
		completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedReplacing userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Removing /var/jb symlink failed with error: %@", error]}]);
		return;
	}
	}
	
	// Clean up xinaA15 v1 leftovers if desired
	NSArray *xinaLeftoverSymlinks = @[
		@"/var/alternatives",
		@"/var/ap",
		@"/var/apt",
		@"/var/bin",
		@"/var/bzip2",
		@"/var/cache",
		@"/var/dpkg",
		@"/var/etc",
		@"/var/gzip",
		@"/var/lib",
		@"/var/Lib",
		@"/var/libexec",
		@"/var/Library",
		@"/var/LIY",
		@"/var/Liy",
		@"/var/local",
		@"/var/newuser",
		@"/var/profile",
		@"/var/sbin",
		@"/var/suid_profile",
		@"/var/sh",
		@"/var/sy",
		@"/var/share",
		@"/var/ssh",
		@"/var/sudo_logsrvd.conf",
		@"/var/suid_profile",
		@"/var/sy",
		@"/var/usr",
		@"/var/zlogin",
		@"/var/zlogout",
		@"/var/zprofile",
		@"/var/zshenv",
		@"/var/zshrc",
		@"/var/log/dpkg",
		@"/var/log/apt",
	];
	NSArray *xinaLeftoverFiles = @[
		@"/var/lib",
		@"/var/master.passwd",
		@"/var/.keep_symlinks",
	];
	
	for (NSString *xinaLeftoverSymlink in xinaLeftoverSymlinks) {
		[self deleteSymlinkAtPath:xinaLeftoverSymlink error:nil];
	}
	
	for (NSString *xinaLeftoverFile in xinaLeftoverFiles) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:xinaLeftoverFile]) {
		[[NSFileManager defaultManager] removeItemAtPath:xinaLeftoverFile error:nil];
		}
	}
	
	if([self doBootstrap:completion] == 0) {
	
	//update jailbreakInfo.rootPath
	[[DOEnvironmentManager sharedManager] locateJailbreakRoot];
	
	[[DOUIManager sharedInstance] sendLog:@"Updating BaseBin" debug:NO];
	
	NSError* error=nil;
	if ([[NSFileManager defaultManager] fileExistsAtPath:jbroot(@"/basebin")]) {
		if (![[NSFileManager defaultManager] removeItemAtPath:jbroot(@"/basebin") error:&error]) {
		completion([NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedExtracting userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed deleting existing basebin file with error: %@", error.localizedDescription]}]);
		return;
		}
	}
	error = [self extractTar:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"] toPath:JBROOT_PATH(@"/")];
	if (error) {
		completion(error);
		return;
	}
	[self patchBasebinDaemonPlists];
	[[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/basebin/basebin.tc") error:nil];
	NSString* systemhookFilePath = [NSString stringWithFormat:@"%@/systemhook-%016llX.dylib", JBROOT_PATH(@"/basebin"), jbrand()];
	[[NSFileManager defaultManager] copyItemAtPath:JBROOT_PATH(@"/basebin/systemhook.dylib") toPath:systemhookFilePath error:nil];
	
	JBFixMobilePermissions();
	
	completion(nil);
	}
}

- (NSError *)finalizeBootstrap
{
	// Initial setup on first jailbreak
	if ([[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/prep_bootstrap.sh")]) {
	[[DOUIManager sharedInstance] sendLog:@"Finalizing Bootstrap" debug:NO];
	int r = exec_cmd_trusted(JBROOT_PATH("/bin/sh"), "/prep_bootstrap.sh", NULL);
	if (r != 0) {
		return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"prep_bootstrap.sh returned %d\n", r]}];
	}
	
	NSError *error = [self installPackageManagers];
	if (error) return error;
	
	NSString *roothideManager = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"roothideapp.deb"];
	 r = [self installPackage:roothideManager];
	if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install roothideManager: %d\n", r]}];
	}
	else
	{
	[[DOUIManager sharedInstance] sendLog:@"Updating Symlinks" debug:NO];
	int r = exec_cmd_trusted(JBROOT_PATH("/bin/sh"), "/usr/libexec/updatelinks.sh", NULL);
	if (r != 0) {
		return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"updatelinks.sh returned %d\n", r]}];
	}
	}
	
	BOOL shouldInstallLibkrw = [self shouldInstallPackage:@"libkrw0-dopamine"];
	BOOL shouldInstallBasebinLink = [self shouldInstallPackage:@"dopamine-basebin-link"];
	
	if (shouldInstallLibkrw || shouldInstallBasebinLink) {
	[[DOUIManager sharedInstance] sendLog:@"Updating Bundled Packages" debug:NO];
	
	if (shouldInstallLibkrw) {
		NSString *libkrwPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"libkrw-dopamine.deb"];
		int r = [self installPackage:libkrwPath];
		if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install the libkrw plugin: %d\n", r]}];
	}
	
	if (shouldInstallBasebinLink) {
		// Clean symlinks from earlier Dopamine versions
		if (![self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/opainject")]) {
		[[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/opainject") error:nil];
		}
		if (![self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/jbctl")]) {
		[[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/jbctl") error:nil];
		}
		if (![self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/lib/libjailbreak.dylib")]) {
		[[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/lib/libjailbreak.dylib") error:nil];
		}
		if (![self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/bin/libjailbreak.dylib")]) {
		// Yes this exists >.< was a typo
		[[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/bin/libjailbreak.dylib") error:nil];
		}

		NSString *basebinLinkPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin-link.deb"];
		int r = [self installPackage:basebinLinkPath];
		if (r != 0) return [NSError errorWithDomain:bootstrapErrorDomain code:BootstrapErrorCodeFailedFinalising userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to install basebin link: %d\n", r]}];
	}
	}

	if ([self fileOrSymlinkExistsAtPath:JBROOT_PATH(@"/usr/lib/libroot.dylib")]) {
	[[NSFileManager defaultManager] removeItemAtPath:JBROOT_PATH(@"/usr/lib/libroot.dylib") error:nil];
	}
	
	NSError* error=nil;
	[[NSFileManager defaultManager] copyItemAtPath:[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"libroot.dylib"] toPath:JBROOT_PATH(@"/basebin/libroot.dylib") error:&error];
	if(error) return error;
	
	[[NSString stringWithFormat:@"%d",DOPAMINE_INSTALL_VERSION] writeToFile:JBROOT_PATH(@"/.installed_dopamine") atomically:YES encoding:NSUTF8StringEncoding error:nil];
	
	return nil;
}

- (NSError *)deleteBootstrap
{
	//jbroot unavailable now
	
	NSError* error=nil;
	NSFileManager* fm = NSFileManager.defaultManager;
	
	NSString* dirpath = @"/var/containers/Bundle/Application/";
	for(NSString* item in [fm directoryContentsAtPath:dirpath])
	{
	if(is_jbroot_name(item.UTF8String)) {
		STRAPLOG("remove %@ @ %@", item, dirpath);
		if(![fm removeItemAtPath:[dirpath stringByAppendingPathComponent:item] error:&error])
		return error;
	}
	}
	
	dirpath = @"/var/mobile/Containers/Shared/AppGroup/";
	for(NSString* item in [fm directoryContentsAtPath:dirpath])
	{
	if(is_jbroot_name(item.UTF8String)) {
		STRAPLOG("remove %@ @ %@", item, dirpath);
		if(![fm removeItemAtPath:[dirpath stringByAppendingPathComponent:item] error:&error])
		return error;
	}
	}
	
	return nil;
}


@end
