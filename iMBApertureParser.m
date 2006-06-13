/*
 
 Permission is hereby granted, free of charge, to any person obtaining a 
 copy of this software and associated documentation files (the "Software"), 
 to deal in the Software without restriction, including without limitation 
 the rights to use, copy, modify, merge, publish, distribute, sublicense, 
 and/or sell copies of the Software, and to permit persons to whom the Software 
 is furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in 
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS 
 FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR 
 COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
 AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION 
 WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 
 Please send fixes to
	<ghulands@framedphotographics.com>
	<ben@scriptsoftware.com>
 */

#import "iMBApertureParser.h"
#import "iMedia.h"

@implementation iMBApertureParser

+ (void)load
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	//[iMediaBrowser registerParser:[self class] forMediaType:@"photos"];
	
	[pool release];
}

- (id)init
{
	CFPropertyListRef db = CFPreferencesCopyAppValue((CFStringRef)@"LibraryPath", (CFStringRef)@"com.apple.Aperture");	
	NSString *path = [(NSString *)db stringByExpandingTildeInPath];
	
	if (self = [super initWithContentsOfFile:path])
	{
		myFolderIcon = [NSImage imageResourceNamed:@"icon-folder.tiff" fromApplication:@"com.apple.Aperture" fallbackTo:@"folder"];
		myProjectIcon = [NSImage imageResourceNamed:@"Project_I_Project.tiff" fromApplication:@"com.apple.Aperture" fallbackTo:@"folder"];
	}
	return self;
}

- (void)dealloc
{
	[myFolderIcon release];
	[myProjectIcon release];
	
	[super dealloc];
}

- (iMBLibraryNode *)recursivelyParseFolder:(NSManagedObject *)folder
{
	iMBLibraryNode *node = [[iMBLibraryNode alloc] init];
	NSString *name = [folder valueForKey:@"name"];
	
	if ([name isEqualToString:@"   Built-in Smart Albums"])
	{
		[node release];
		return nil;
	}
	else
	{
		[node setName:[name stringByDeletingPathExtension]];
		if ([[name pathExtension] isEqualToString:@"approject"])
		{
			[node setIcon:myProjectIcon];
		}
		else
		{
			[node setIcon:myFolderIcon];
		}
			
		NSManagedObjectContext *moc = [folder managedObjectContext];
		NSError *error;
		NSFetchRequest *folderFetch = [[[NSFetchRequest alloc] init] autorelease];
		[folderFetch setEntity:[NSEntityDescription entityForName:@"RKFolder" inManagedObjectContext:moc]];
		[folderFetch setPredicate:[NSPredicate predicateWithFormat:@"parentFolder = %@", folder]];
		
		NSArray *folders = [moc executeFetchRequest:folderFetch error:&error];
		NSEnumerator *e = [folders objectEnumerator];
		NSManagedObject *cur;
		iMBLibraryNode *subNode;
		
		while (cur = [e nextObject])
		{
			subNode = [self recursivelyParseFolder:cur];
			if (subNode)
			{
				[node addItem:subNode];
			}
		}
		
		// get the images for the current folder
		NSString *folderPath = [[self databasePath] stringByAppendingPathComponent:[folder valueForKey:@"libraryRelativePath"]];
		
	}
	
	
	return [node autorelease];
}

- (iMBLibraryNode *)parseDatabase
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *libraryPath = [[self databasePath] stringByAppendingPathComponent:@"Aperture.aplib/Library.apdb"];
	if (![fm fileExistsAtPath:libraryPath]) return nil;
	
	iMBLibraryNode *root = [[iMBLibraryNode alloc] init];
	[root setName:LocalizedStringInThisBundle(@"Aperture", @"Aperture Node Name")];
	[root setIconName:@"com.apple.Aperture"];
	
	NSString *aperturePath = [[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:@"com.apple.Aperture"];
	NSBundle *bundle = [NSBundle bundleWithPath:aperturePath];
	NSString *mom = [bundle pathForResource:@"RKDataModel" ofType:@"mom"];
	NSError *error;
	
	NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:mom]];
	NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
	[psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:libraryPath] options:nil error:&error];
	[model release];
	
	NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] init];
	[moc setPersistentStoreCoordinator:psc];
	
	// get the root folder
	NSFetchRequest *folderFetch = [[[NSFetchRequest alloc] init] autorelease];
	[folderFetch setEntity:[NSEntityDescription entityForName:@"RKFolder" inManagedObjectContext:moc]];
	[folderFetch setPredicate:[NSPredicate predicateWithFormat:@"parentFolder = nil"]];
	NSManagedObject *rootFolder = [[moc executeFetchRequest:folderFetch error:&error] objectAtIndex:0];
	
	// get the folders of the root
	folderFetch = [[[NSFetchRequest alloc] init] autorelease];
	[folderFetch setEntity:[NSEntityDescription entityForName:@"RKFolder" inManagedObjectContext:moc]];
	[folderFetch setPredicate:[NSPredicate predicateWithFormat:@"parentFolder = %@", rootFolder]];
	
	NSArray *folders = [moc executeFetchRequest:folderFetch error:&error];
	NSEnumerator *e = [folders objectEnumerator];
	iMBLibraryNode *node;
	NSManagedObject *cur;
	
	while (cur = [e nextObject])
	{
		node = [self recursivelyParseFolder:cur];
		if (node)
		{
			[root addItem:node];
		}
	}

	[moc release];
	[psc release];
	
	return [root autorelease];
}

@end

/*
 
 NSMutableString *dump = [NSMutableString stringWithFormat:@"Dump of %@", mom];
	e = [[model entitiesByName] keyEnumerator];
	NSString *entityName;
	
	while (entityName = [e nextObject])
	{
		id entity = [[model entitiesByName] objectForKey:entityName];
		[dump appendFormat:@"%@:\nAttributes\n", entityName];
		NSEnumerator *g = [[entity attributesByName] keyEnumerator];
		id attribName;
		while (attribName = [g nextObject])
		{
			id attrib = [[entity attributesByName] objectForKey:attribName];
			[dump appendFormat:@"\t%@ - %@\n", attribName, [attrib attributeValueClassName]];
		}
		[dump appendString:@"Relationships\n"];
		g = [[entity relationshipsByName] keyEnumerator];
		id relName;
		
		while (relName = [g nextObject])
		{
			id relationship = [[entity relationshipsByName] objectForKey:relName];
			[dump appendFormat:@"\t%@ -> %@ (%@)\n", relName, [[relationship destinationEntity] name], [[relationship inverseRelationship] name]];
		}
	}
	NSLog(@"%@", dump); 
	NSLog(@"%@", [[[NSEntityDescription entityForName:@"RKMaster" inManagedObjectContext:moc] attributesByName] allKeys]);
	NSLog(@"%@", [[[NSEntityDescription entityForName:@"RKMaster" inManagedObjectContext:moc] relationshipsByName] allKeys]);
 
 */