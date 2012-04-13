/* =============================================================================
	FILE:		UKFSEventsWatcher.m
    
    COPYRIGHT:  (c) 2008 Peter Baumgartner, all rights reserved.
    
	AUTHORS:	Peter Baumgartner
    
    LICENSES:   MIT License

	REVISIONS:
		2008-06-09	PB Created.
   ========================================================================== */

// -----------------------------------------------------------------------------
//  Headers:
// -----------------------------------------------------------------------------

#import "UKFSEventsWatcher.h"
#import <CoreServices/CoreServices.h>

// -----------------------------------------------------------------------------
//  FSEventCallback
//		Private callback that is called by the FSEvents framework
// -----------------------------------------------------------------------------

#if MAC_OS_X_VERSION_MAX_ALLOWED > MAC_OS_X_VERSION_10_4

static void FSEventCallback(ConstFSEventStreamRef inStreamRef, 
							void* inClientCallBackInfo, 
							size_t inNumEvents, 
							void* inEventPaths, 
							const FSEventStreamEventFlags inEventFlags[], 
							const FSEventStreamEventId inEventIds[])
{
	UKFSEventsWatcher* watcher = (UKFSEventsWatcher*)inClientCallBackInfo;
	
	if (watcher != nil && [watcher delegate] != nil)
	{
		id delegate = [watcher delegate];
		
		if ([delegate respondsToSelector:@selector(watcher:receivedNotification:forPath:)])
		{
			NSEnumerator* paths = [(NSArray*)inEventPaths objectEnumerator];
			NSString* path;
			
			while (path = [paths nextObject])
			{
				[delegate watcher:watcher receivedNotification:UKFileWatcherWriteNotification forPath:path];
				
				[[[NSWorkspace sharedWorkspace] notificationCenter] 
					postNotificationName: UKFileWatcherWriteNotification
					object:watcher
					userInfo:[NSDictionary dictionaryWithObjectsAndKeys:path,@"path",nil]];
			}	
		}
	}
}

@implementation UKFSEventsWatcher

// -----------------------------------------------------------------------------
//  sharedFileWatcher:
//		Singleton accessor.
// -----------------------------------------------------------------------------

+(id) sharedFileWatcher
{
	static UKFSEventsWatcher* sSharedFileWatcher = nil;
	static NSString* sSharedFileWatcherMutex = @"UKFSEventsWatcher";
	
	@synchronized(sSharedFileWatcherMutex)
	{
		if (sSharedFileWatcher == nil)
		{
			sSharedFileWatcher = [[UKFSEventsWatcher alloc] init];	// This is a singleton, and thus an intentional "leak".
		}	
    }
	
    return sSharedFileWatcher;
}

// -----------------------------------------------------------------------------
//  * CONSTRUCTOR:
// -----------------------------------------------------------------------------

-(id) init
{
    if (self = [super init])
	{
		latency = 1.0;
		flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot;
		eventStreams = [[NSMutableDictionary alloc] init];
		pathReferenceCounts = [[NSMutableDictionary alloc] init];
    }
	
    return self;
}

// -----------------------------------------------------------------------------
//  * DESTRUCTOR:
// -----------------------------------------------------------------------------

-(void) dealloc
{
	[self removeAllPaths];
    [eventStreams release];
	[pathReferenceCounts release];
    [super dealloc];
}

-(void) finalize
{
	[self removeAllPaths];
    [super finalize];
}

// -----------------------------------------------------------------------------
//  setLatency:
//		Time that must pass before events are being sent.
// -----------------------------------------------------------------------------

- (void) setLatency:(CFTimeInterval)inLatency
{
	latency = inLatency;
}

// -----------------------------------------------------------------------------
//  latency
//		Time that must pass before events are being sent.
// -----------------------------------------------------------------------------

- (CFTimeInterval) latency
{
	return latency;
}

// -----------------------------------------------------------------------------
//  setFSEventStreamCreateFlags:
//		See FSEvents.h for meaning of these flags.
// -----------------------------------------------------------------------------

- (void) setFSEventStreamCreateFlags:(FSEventStreamCreateFlags)inFlags
{
	flags = inFlags;
}

// -----------------------------------------------------------------------------
//  fsEventStreamCreateFlags
//		See FSEvents.h for meaning of these flags.
// -----------------------------------------------------------------------------

- (FSEventStreamCreateFlags) fsEventStreamCreateFlags
{
	return flags;
}

// -----------------------------------------------------------------------------
//  setDelegate:
//		Mutator for file watcher delegate.
// -----------------------------------------------------------------------------

-(void) setDelegate: (id)newDelegate
{
    delegate = newDelegate;
}

// -----------------------------------------------------------------------------
//  delegate:
//		Accessor for file watcher delegate.
// -----------------------------------------------------------------------------

-(id)   delegate
{
    return delegate;
}

// -----------------------------------------------------------------------------
//  parentFolderForFilePath:
//		We need to supply a folder to FSEvents, so if we were passed a path  
//		to a file, then convert it to the parent folder path...
// -----------------------------------------------------------------------------

- (NSString*) pathToParentFolderOfFile:(NSString*)inPath
{
	BOOL directory;
	BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:inPath isDirectory:&directory];
	BOOL package = [[NSWorkspace sharedWorkspace] isFilePackageAtPath:inPath];
	
	if (exists && directory==NO && package==NO)
	{
		inPath = [inPath stringByDeletingLastPathComponent];
	}
	
	return inPath;		
}

// -----------------------------------------------------------------------------
//  addPath:
//		Start watching the folder at the specified path. 
// -----------------------------------------------------------------------------

-(void) addPath: (NSString*)path
{
	BOOL succeeded = YES;
	path = [self pathToParentFolderOfFile:path];
	NSArray* paths = [NSArray arrayWithObject:path];

	NSUInteger currentRegistrationCount = 0;

	// Do we already have a stream scheduled for this path?
	// NOTE: Synchronize the whole thing so we don't run the risk of the current count changing while 
	// we're busy updating it with our new addition.
	@synchronized (self)
	{
		NSNumber* currentRegistrationCountNumber = [pathReferenceCounts objectForKey:path];
		if (currentRegistrationCountNumber != nil)
		{
			currentRegistrationCount = [currentRegistrationCountNumber unsignedIntValue];
		} 		
	
		if (currentRegistrationCount == 0)
		{
			FSEventStreamContext context;
			context.version = 0;
			context.info = (void*) self;
			context.retain = NULL;
			context.release = NULL;
			context.copyDescription = NULL;
						
			FSEventStreamRef stream = FSEventStreamCreate(NULL,&FSEventCallback,&context,(CFArrayRef)paths,kFSEventStreamEventIdSinceNow,latency,flags);

			if (stream)
			{
				FSEventStreamScheduleWithRunLoop(stream,CFRunLoopGetMain(),kCFRunLoopCommonModes);
				FSEventStreamStart(stream);

				[eventStreams setObject:[NSValue valueWithPointer:stream] forKey:path];
			}	
			else
			{
				NSLog( @"UKFSEventsWatcher addPath:%@ failed",path);
				succeeded = NO;
			}
		}		
		
		if (succeeded)
		{
			currentRegistrationCount = currentRegistrationCount + 1;
			NSNumber* newCountNumber = [NSNumber numberWithUnsignedInt:currentRegistrationCount];
			[pathReferenceCounts setObject:newCountNumber forKey:path];
		}
	}
}

// -----------------------------------------------------------------------------
//  removePath:
//		Stop watching the folder at the specified path.
// -----------------------------------------------------------------------------

-(void) removePath: (NSString*)path
{
	// Ensure we are removing a folder, not a file inside the desired folder. This matches
	// the normalization done in addPath to make sure removePath for the same path will succeed.
	path = [self pathToParentFolderOfFile:path];

    NSValue* valueToRemove = nil;
		
    @synchronized (self)
    {
		NSUInteger currentRegistrationCount = 0;
		NSNumber* currentRegistrationCountNumber = [pathReferenceCounts objectForKey:path];
		if (currentRegistrationCountNumber != nil)
		{
			currentRegistrationCount = [currentRegistrationCountNumber unsignedIntValue];
		}
		
		// We are sometimes asked to removePath on a path that we were never asked to add. That's 
		// OK - it just means they are being extra-certain before (probably) adding it for the 
		// first time...
		if (currentRegistrationCount > 0)
		{
			NSUInteger newRegistrationCount = currentRegistrationCount - 1;
			
			// Clear everything out if we've gone to zero, otherwise just update with te new count
			if (newRegistrationCount == 0)
			{
				valueToRemove = [[[eventStreams objectForKey:path] retain] autorelease];
				[eventStreams removeObjectForKey:path];				
				[pathReferenceCounts removeObjectForKey:path];
			}
			else
			{
				[pathReferenceCounts setObject:[NSNumber numberWithUnsignedInt:newRegistrationCount] forKey:path];
			}
		}
    }
    
	if (valueToRemove)
	{
		FSEventStreamRef stream = [valueToRemove pointerValue];
		
		if (stream)
		{
			FSEventStreamStop(stream);
			FSEventStreamInvalidate(stream);
			FSEventStreamRelease(stream);
		}
	}
}

// -----------------------------------------------------------------------------
//  removeAllPaths:
//		Stop watching all known folders.
// -----------------------------------------------------------------------------

-(void) removeAllPaths
{
    NSEnumerator* paths = [[eventStreams allKeys] objectEnumerator];
	NSString* path;
	
	while (path = [paths nextObject])
	{
		// Kind of a hack, but to get the remove to work as expected, we need
		// to make sure the reference count shows up as 1. The client in this 
		// case is asking us to disregard all reference counts and just remove
		// everything ...
		@synchronized (self)
		{
			[pathReferenceCounts setObject:[NSNumber numberWithUnsignedInt:1] forKey:path];
		}
		
		[self removePath:path];
	}
}

@end

#endif

