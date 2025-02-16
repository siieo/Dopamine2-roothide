#import <Foundation/Foundation.h>
#import <spawn.h>
#include <roothide.h>
#import "common.h"

extern char **environ;

#pragma GCC diagnostic ignored "-Wobjc-method-access"
#pragma GCC diagnostic ignored "-Wunused-variable"

#define PROC_PIDPATHINFO_MAXSIZE	(4 * MAXPATHLEN)

// Helper: Retrieve the process path for a given NSXPCConnection.
static BOOL getProcessPath(NSXPCConnection *xpc, char *pathbuf, size_t size) {
	if (!xpc || !pathbuf) return NO;
	if (proc_pidpath(xpc.processIdentifier, pathbuf, size) <= 0) {
		NSLog(@"Unable to get proc path for %d", xpc.processIdentifier);
		return NO;
	}
	return YES;
}

%hook _LSCanOpenURLManager

- (BOOL)canOpenURL:(NSURL *)url publicSchemes:(BOOL)ispublic privateSchemes:(BOOL)isprivate XPCConnection:(NSXPCConnection *)xpc error:(NSError *)err {
	BOOL result = %orig;
	if (!result || !xpc) return result;
	
	char pathbuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
	if (!getProcessPath(xpc, pathbuf, sizeof(pathbuf))) return result;
	
	NSLog(@"canOpenURL:%@ publicSchemes:%d privateSchemes:%d XPCConnection:%@ proc:%d, %s",
		  url, ispublic, isprivate, xpc, xpc.processIdentifier, pathbuf);
	
	NSArray *jbschemes = @[
		@"filza",
		@"db-lmvo0l08204d0a0",
		@"boxsdk-810yk37nbrpwaee5907xc4iz8c1ay3my",
		@"com.googleusercontent.apps.802910049260-0hf6uv6nsj21itl94v66tphcqnfl172r",
		@"sileo",
		@"zbra",
		@"santander",
		@"icleaner",
		@"xina",
		@"ssh",
		@"apt-repo",
		@"cydia",
		@"activator",
		@"postbox"
	];
	
	if (isSandboxedApp(xpc.processIdentifier, pathbuf)) {
		// Using lowercaseString on the URL scheme for consistency.
		if ([jbschemes containsObject:url.scheme.lowercaseString]) {
			NSLog(@"Blocking %@ for %s", url, pathbuf);
			return NO;
		}
	}
	
	return result;
}

%end

%hook _LSQueryContext

- (NSMutableDictionary *)_resolveQueries:(NSMutableSet *)queries XPCConnection:(NSXPCConnection *)xpc error:(NSError *)err {
	NSMutableDictionary *result = %orig;
	if (!result || !xpc) return result;
	
	char pathbuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
	if (!getProcessPath(xpc, pathbuf, sizeof(pathbuf))) return result;
	
	if (!isNormalAppPath(pathbuf)) return result;
	
	NSLog(@"_resolveQueries:%@:%@ XPCConnection:%@ result=%@/%lu proc:%d, %s",
		  [queries class], queries, xpc, [result class], (unsigned long)result.count,
		  xpc.processIdentifier, pathbuf);
	
	for (id key in result) {
		NSLog(@"key type: %@, value type: %@", [key class], [[result objectForKey:key] class]);
		
		if ([key isKindOfClass:NSClassFromString(@"LSPlugInQueryWithUnits")] ||
			[key isKindOfClass:NSClassFromString(@"LSPlugInQueryWithIdentifier")] ||
			[key isKindOfClass:NSClassFromString(@"LSPlugInQueryWithQueryDictionary")]) {
			
			NSMutableArray *plugins = result[key];
			NSLog(@"plugins bundle count=%lu", (unsigned long)plugins.count);
			
			NSMutableIndexSet *removed = [[NSMutableIndexSet alloc] init];
			for (NSUInteger i = 0; i < plugins.count; i++) {
				id plugin = plugins[i];
				id appbundle = [plugin performSelector:@selector(containingBundle)];
				if (!appbundle) continue;
				
				NSURL *bundleURL = [appbundle performSelector:@selector(bundleURL)];
				if (isJailbreakPath(bundleURL.path.fileSystemRepresentation)) {
					NSLog(@"Removing plugin %@ (%@)", plugin, bundleURL);
					[removed addIndex:i];
				}
			}
			
			[plugins removeObjectsAtIndexes:removed];
			NSLog(@"New plugins bundle count=%lu", (unsigned long)plugins.count);
			
			if ([key isKindOfClass:NSClassFromString(@"LSPlugInQueryWithUnits")]) {
				NSMutableArray *units = [[key valueForKey:@"_pluginUnits"] mutableCopy];
				[units removeObjectsAtIndexes:removed];
				[key setValue:[units copy] forKey:@"_pluginUnits"];
				NSLog(@"LSPlugInQueryWithUnits: new _pluginUnits count=%lu",
					  (unsigned long)[[key valueForKey:@"_pluginUnits"] count]);
			} else if ([key isKindOfClass:NSClassFromString(@"LSPlugInQueryWithQueryDictionary")]) {
				NSLog(@"LSPlugInQueryWithQueryDictionary: _queryDict=%@", [key valueForKey:@"_queryDict"]);
				NSLog(@"LSPlugInQueryWithQueryDictionary: _extensionIdentifiers=%@", [key valueForKey:@"_extensionIdentifiers"]);
				NSLog(@"LSPlugInQueryWithQueryDictionary: _extensionPointIdentifiers=%@", [key valueForKey:@"_extensionPointIdentifiers"]);
			} else if ([key isKindOfClass:NSClassFromString(@"LSPlugInQueryWithIdentifier")]) {
				NSLog(@"LSPlugInQueryWithIdentifier: _identifier=%@", [key valueForKey:@"_identifier"]);
			}
		} else if ([key isKindOfClass:NSClassFromString(@"LSPlugInQueryAllUnits")]) {
			NSMutableArray *unitsArray = result[key];
			for (NSUInteger i = 0; i < unitsArray.count; i++) {
				id unitsResult = unitsArray[i];
				NSUUID *dbUUID = [unitsResult valueForKey:@"_dbUUID"];
				NSArray *pluginUnits = [unitsResult valueForKey:@"_pluginUnits"];
				NSLog(@"LSPlugInQueryAllUnits: _dbUUID=%@, _pluginUnits count=%lu",
					  dbUUID, (unsigned long)pluginUnits.count);
				
				id unitQuery = [[NSClassFromString(@"LSPlugInQueryWithUnits") alloc] initWithPlugInUnits:pluginUnits forDatabaseWithUUID:dbUUID];
				NSMutableDictionary *queriesResult = [self _resolveQueries:[NSSet setWithObject:unitQuery]
															   XPCConnection:xpc error:err];
				if (queriesResult) {
					for (id queryKey in queriesResult) {
						NSArray *newPluginUnits = [queryKey valueForKey:@"_pluginUnits"];
						[unitsResult setValue:newPluginUnits forKey:@"_pluginUnits"];
						NSLog(@"LSPlugInQueryAllUnits: new _pluginUnits count=%lu",
							  (unsigned long)newPluginUnits.count);
					}
				}
			}
		}
	}
	
	return result;
}

%end

// Hook for LSGetInboxURLForBundleIdentifier.
NSURL * (*orig_LSGetInboxURLForBundleIdentifier)(NSString *bundleIdentifier) = NULL;
NSURL * new_LSGetInboxURLForBundleIdentifier(NSString *bundleIdentifier) {
	NSURL *pathURL = orig_LSGetInboxURLForBundleIdentifier(bundleIdentifier);
	
	if (![bundleIdentifier hasPrefix:@"com.apple."] &&
		[pathURL.path hasPrefix:@"/var/mobile/Library/Application Support/Containers/"]) {
		NSLog(@"Redirect Inbox %@ : %@", bundleIdentifier, pathURL);
		pathURL = [NSURL fileURLWithPath:jbroot(pathURL.path)];
	}
	
	return pathURL;
}

// Hook for LSServer_RebuildApplicationDatabases.
int (*orig_LSServer_RebuildApplicationDatabases)() = NULL;
int new_LSServer_RebuildApplicationDatabases() {
	int r = orig_LSServer_RebuildApplicationDatabases();
	
	if (access(jbroot("/.disable_auto_uicache"), F_OK) == 0)
		return r;
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		const char *uicachePath = jbroot("/usr/bin/uicache");
		if (access(uicachePath, F_OK) == 0) {
			char * const args[] = {"/usr/bin/uicache", "-a", NULL};
			posix_spawn(NULL, uicachePath, NULL, NULL, args, environ);
		}
	});
	
	return r;
}

void lsdInit(void) {
	NSLog(@"lsdInit...");
	
	MSImageRef coreServicesImage = MSGetImageByName("/System/Library/Frameworks/CoreServices.framework/CoreServices");
	
	void *symbolInbox = MSFindSymbol(coreServicesImage, "__LSGetInboxURLForBundleIdentifier");
	NSLog(@"coreServicesImage=%p, _LSGetInboxURLForBundleIdentifier=%p", coreServicesImage, symbolInbox);
	if (symbolInbox) {
		MSHookFunction(symbolInbox,
					   (void *)&new_LSGetInboxURLForBundleIdentifier,
					   (void **)&orig_LSGetInboxURLForBundleIdentifier);
	}
	
	void *symbolRebuild = MSFindSymbol(coreServicesImage, "__LSServer_RebuildApplicationDatabases");
	NSLog(@"coreServicesImage=%p, _LSServer_RebuildApplicationDatabases=%p", coreServicesImage, symbolRebuild);
	if (symbolRebuild) {
		MSHookFunction(symbolRebuild,
					   (void *)&new_LSServer_RebuildApplicationDatabases,
					   (void **)&orig_LSServer_RebuildApplicationDatabases);
	}
	
	%init();
}