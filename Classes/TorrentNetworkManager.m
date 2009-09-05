//
//  TorrentNetworkManager.m
//  uTorrentView
//
//  Created by Mike Godenzi on 12/22/08.
//  Copyright 2008 __MyCompanyName__. All rights reserved.
//

#import "TorrentNetworkManager.h"

#import "Utilities.h"
#import "TorrentListener.h"
#import "uTorrentConstants.h"
#import "uTorrentViewAppDelegate.h"

#import <SystemConfiguration/SCNetworkConnection.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>

#import <JSON/JSON.h>

@implementation TorrentNetworkManager
	
@synthesize torrentsData;
@synthesize labelsData;
@synthesize torrentsCacheID;
@synthesize unlabelledTorrents;
@synthesize removedTorrents;
@synthesize needToDelete;
@synthesize settingsAddress, settingsPort, settingsUname, settingsPassword;

- (id)init {
	if (self = [super init]) {
        listeners = [[NSMutableArray alloc] init];
		needListUpdate = NO;
		self.needToDelete = NO;
		hasReceivedResponse = YES;
		
		// load User settings
		settingsAddress = [[NSUserDefaults standardUserDefaults] stringForKey:@"address_preference"];
		settingsPort = [[NSUserDefaults standardUserDefaults] stringForKey:@"uport_preference"];
		settingsUname = [[NSUserDefaults standardUserDefaults] stringForKey:@"username_preference"];
		settingsPassword = [[NSUserDefaults standardUserDefaults] stringForKey:@"pwd_preference"];
    }
    return self;
}

/*
 * TODO: this class may need HUGE refactoring
 * the cache_ID doesn't seem to work, I always get back the full list of torrents.
 * on the forum it says that uTorrent can only remember _1_ cacheID, so if checking for it, make sure nobody else is using the webui
 */

- (BOOL)connectedToNetwork {
	struct sockaddr_in zeroAddress;
	bzero(&zeroAddress, sizeof(zeroAddress));
	zeroAddress.sin_len = sizeof(zeroAddress);
	zeroAddress.sin_family = AF_INET;
	
	SCNetworkReachabilityRef defaultRouteReachability = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *) &zeroAddress);
	SCNetworkReachabilityFlags flags;
	
	BOOL didRetrieveFlags = SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags);
	CFRelease(defaultRouteReachability);
	
	if (!didRetrieveFlags) {
		printf("Error. Could not recover network reachability flags\n");
		return 0;
	}
	
	BOOL isReachable = flags & kSCNetworkFlagsReachable;
	BOOL needsConnection = flags & kSCNetworkFlagsConnectionRequired;
	return (isReachable && !needsConnection) ? YES : NO;
}

- (BOOL)hostAvailable: (NSString *) theHost {
	NSString *addressString = [self getIPAddressForHost:theHost];
	if (!addressString) {
		printf("Error recovering IP address from host name\n");
		return NO;
	}
	
	struct sockaddr_in address;
	BOOL gotAddress = [self addressFromString:addressString address:&address];
	
	if (!gotAddress) {
		printf("Error recovering sockaddr address from %s\n", [addressString UTF8String]);
		return NO;
	}
	
	SCNetworkReachabilityRef defaultRouteReachability = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&address);
	SCNetworkReachabilityFlags flags;
	
	BOOL didRetrieveFlags = SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags);
	CFRelease(defaultRouteReachability);
	
	if (!didRetrieveFlags) {
		printf("Error. Could not recover network reachability flags\n");
		return NO;
	}
	
	BOOL isReachable = flags & kSCNetworkFlagsReachable;
	return isReachable ? YES : NO;
}

- (BOOL)addressFromString: (NSString *)IPAddress address:(struct sockaddr_in *) address {
	if (!IPAddress || ![IPAddress length]) {
		return NO;
	}
	
	memset((char *) address, sizeof(struct sockaddr_in), 0);
	address->sin_family = AF_INET;
	address->sin_len = sizeof(struct sockaddr_in);
	
	int conversionResult = inet_aton([IPAddress UTF8String], &address->sin_addr);
	if (conversionResult == 0) {
		NSAssert1(conversionResult != 1, @"Failed to convert the IP address string into a sockaddr_in: %@", IPAddress);
		return NO;
	}
	
	return YES;
}

- (NSString *)getIPAddressForHost: (NSString *) theHost {
	struct hostent *host = gethostbyname([theHost UTF8String]);
	
	if (host == NULL) {
		herror("resolv");
		return NULL;
	}
	
	struct in_addr **list = (struct in_addr **)host->h_addr_list;
	NSString *addressString = [NSString stringWithCString:inet_ntoa(*list[0]) encoding:NSUTF8StringEncoding];
	return addressString;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
	//NSLog(@"didReceiveResonse called: %@", response);
    // this method is called when the server has determined that it
    // has enough information to create the NSURLResponse
	
    // it can be called multiple times, for example in the case of a
    // redirect, so each time we reset the data.
    // receivedData is declared as a method instance elsewhere
    [receivedData setLength:0];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    // append the new data to the receivedData
    // receivedData is declared as a method instance elsewhere
	//NSLog(@"didReceiveData got called\n");
    [receivedData appendData:data];
}

-(void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
	//NSLog(@"connectiondidReceiveAuthenticationChallenge got called\n");
    if ([challenge previousFailureCount] == 0) {
        NSURLCredential * newCredential;
        newCredential = [NSURLCredential credentialWithUser:(settingsUname == nil) ? @"" : settingsUname
                                                   password:(settingsPassword == nil) ? @"" : settingsPassword
                                                persistence:NSURLCredentialPersistenceNone];
        [[challenge sender] useCredential:newCredential forAuthenticationChallenge:challenge];
    } else {
        [[challenge sender] cancelAuthenticationChallenge:challenge];
        // inform the user that the user name and password
        // in the preferences are incorrect
		//[Utilities createAndShowAlertWithTitle:@"Credentials Incorrect" andMessage:@"Username or Password incorrect" withDelegate:self];
		UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Credentials Problem" 
														message:@"Username and/or Password are incorrect\nPlease check your settings\n ... Exit on OK ..."
													   delegate:self 
											  cancelButtonTitle:@"OK" otherButtonTitles: nil];
		alert.tag = 13371007;
		[alert show];	
		[alert release];
	}
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
	hasReceivedResponse = YES;
    // release the connection, and the data object
    [connection release];
    // receivedData is declared as a method instance elsewhere
    [receivedData release];
	
	NSString * message;
    // inform the user
	switch ([error code]) {
		case -1012: // credentials incorrect - handled in another funtion (just above)
			return;
		default:
			message = [[@"Error - " stringByAppendingString:[error localizedDescription]] stringByAppendingString:@"\nPlease check your settings"];
			break;
	}
	[Utilities createAndShowAlertWithTitle:@"Network Problem" andMessage:message withDelegate:self andTag:13371007];
}

- (void)alertView:(UIAlertView *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
	NSInteger problem;
	id obj;
	
	if (actionSheet.tag == 13371007)
		problem = T_NETWORK_PROBLEM;
	else
		problem = T_DOWNLOAD_PROBLEM;
	
	NSEnumerator * enumerator = [listeners objectEnumerator];
	while (obj = [enumerator nextObject]) {
		id<TorrentListener> listener = (id<TorrentListener>)obj;
		[listener update:problem];
	}
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
	hasReceivedResponse = YES;
    // do something with the data
    // receivedData is declared as a method instance elsewhere
    //NSLog(@"Succeeded! Received %d bytes of data",[receivedData length]);
	
	NSString * readableString = [[NSString alloc] initWithData:receivedData encoding:NSUTF8StringEncoding];
	// Uncomment to see what is returned from the network call
	
	NSDictionary * jsonItem = [readableString JSONValue];
	if (!jsonItem) { // something wrong with the settings
		// stop the spinning
		[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
		
		// release the connection, and the data object
		[connection release];
		[receivedData release];
		[readableString release];
		[Utilities createAndShowAlertWithTitle:@"Network Problem" 
									andMessage:@"There's something wrong evaluating the JSON answer from the server. \n Either check the settings or contact the developers!" 
								  withDelegate:self 
										andTag:13371008];
		return;
	}
	
	// if checks because following requests (actions) won't return the list
	if ([jsonItem objectForKey:@"torrents"] != nil) { // new request -> no cache
		self.torrentsData = [NSMutableArray arrayWithArray:[jsonItem objectForKey:@"torrents"]];
	} else if ([jsonItem objectForKey:@"torrentp"] != nil) { // cache id being used - this are the modified torrents
		//[self.removedTorrents release];
		self.removedTorrents = [jsonItem objectForKey:@"torrentm"];
		if (self.removedTorrents != nil) {
			for (NSString * removedTorrentHash in self.removedTorrents) {
				for (NSArray* oldTorrent in torrentsData) {
					NSString * oldHash = [oldTorrent objectAtIndex:HASH];
					if ([removedTorrentHash isEqual:oldHash])
						[torrentsData removeObject:oldTorrent];
				}
			}
		}
		for (NSArray* newTorrent in [jsonItem objectForKey:@"torrentp"]) {
			for (NSArray* oldTorrent in torrentsData) {
				NSString * newHash = [newTorrent objectAtIndex:HASH];
				NSString * oldHash = [oldTorrent objectAtIndex:HASH];
				if ([newHash isEqual:oldHash]) {
					[torrentsData removeObject:oldTorrent];
					[torrentsData addObject:newTorrent];
					break;
				} else if ([[torrentsData lastObject] isEqual:oldTorrent]) {
					// if we reached the last object, it means this is a new torrent!
					[torrentsData addObject:newTorrent];
				}
			}
		}
	}
	if ([jsonItem objectForKey:@"label"] != nil) {
		self.labelsData = [NSMutableArray arrayWithArray:[jsonItem objectForKey:@"label"]];
		float randomH;
		NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
		NSArray * labelColorData;
		for (NSArray * label in self.labelsData) {
			if ((labelColorData = [defaults arrayForKey:[label objectAtIndex:0]]) == nil) {
				NSLog(@"%@/%@ not found:", [label objectAtIndex:0], labelColorData);
				// label not found in user defaults, create random color and store it
				randomH = (float) random() / (float) 0x7fffffff;
				NSArray * colorInfo = [[NSArray alloc] initWithObjects:[NSNumber numberWithFloat:randomH], [NSNumber numberWithFloat:1.0f], nil];
				[defaults setObject:colorInfo forKey:[label objectAtIndex:0]];
				[colorInfo release];
			}
		}
		// add color (black) for 'No label' torrents only if it doesn't exist!
		if ([defaults arrayForKey:@"nolabel"] == nil) {
			//NSLog(@"defaults: %@", [defaults arrayForKey:@"nolabel"]);
			NSArray * colorInfo = [[NSArray alloc] initWithObjects:[NSNumber numberWithFloat:1.0f], [NSNumber numberWithFloat:0.1f], nil];
			[defaults setObject:colorInfo forKey:@"nolabel"];
			[colorInfo release];
		}
	}

	if ([jsonItem objectForKey:@"torrentc"] != nil)
		self.torrentsCacheID = [jsonItem objectForKey:@"torrentc"];
	
	// call update method on listeners
	// only if it was a requestList!
	if (needListUpdate == NO) {
		NSEnumerator * enumerator = [listeners objectEnumerator];
		id obj;
		while (obj = [enumerator nextObject]) {
			id<TorrentListener> listener = (id<TorrentListener>)obj;
			[listener update:type];
		}
	}
	
	// stop the spinning
	[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
	
    // release the connection, and the data object
    [connection release];
    [receivedData release];
	[readableString release];
	
	if (needListUpdate)
		[self requestList];
}

- (NSString *)createRequest:(NSString *)request {
	NSString * url = settingsAddress;
	if (![url hasPrefix:@"http://"]) url = [NSString stringWithFormat:@"http://%@", url];
	if ([url hasSuffix:@"/"]) url = [url substringToIndex:[url length] - 1];
	if ([url hasSuffix:@"/gui"]) url = [url substringToIndex:[url length] - 4];
	return [NSString stringWithFormat:@"%@:%@/gui/%@", url, (settingsPort && [settingsPort length] != 0) ? settingsPort : @"80", request];
}

- (void)sendNetworkRequest:(NSString *)request {
	if (!hasReceivedResponse)
		return;
	// create the request
	NSString * url = [self createRequest:request];
	if (url == nil)
		url = @"";
	NSString * urlrequest = [[NSString alloc] initWithFormat:@"%@&cid=%@", url, (self.torrentsCacheID != nil) ? self.torrentsCacheID : @""];

	[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	NSURLRequest *theRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:urlrequest]];
	[urlrequest release];	
	NSURLConnection * theConnection = [[NSURLConnection alloc] initWithRequest:theRequest delegate:self startImmediately:YES];
	if (theConnection) {
		// Create the NSMutableData that will hold
		// the received data
		// receivedData is declared as a method instance elsewhere
		receivedData = [[NSMutableData data] retain];
		hasReceivedResponse = NO;
	} else {
		// inform the user that the download could not be made
		//NSLog(@"download can't be made\n");
		[Utilities createAndShowAlertWithTitle:@"Download Problem" andMessage:@"Download can't be made\nTry restarting the application" withDelegate:self andTag:13371008];
	}
}

- (void)actionStartForTorrent:(NSString *)hash {
	type = T_START;
	needListUpdate = YES;
	NSString * action = @"?action=start&hash=";
	[self sendNetworkRequest:[action stringByAppendingString:hash]];
}

- (void)actionStopForTorrent:(NSString *)hash {
	type = T_STOP;
	needListUpdate = YES;
	NSString * action = @"?action=stop&hash=";
	[self sendNetworkRequest:[action stringByAppendingString:hash]];
}

- (void)actionDeleteDotTorrent:(NSString *)hash {
	type = T_DELETE;
	needListUpdate = YES;
	self.needToDelete = YES;
	NSString * action = @"?action=remove&hash=";
	[self sendNetworkRequest:[action stringByAppendingString:hash]];
}

- (void)actionDeleteData:(NSString *)hash {
	type = T_DELETE;
	needListUpdate = YES;
	self.needToDelete = YES;
	NSString * action = @"?action=removedata&hash=";
	[self sendNetworkRequest:[action stringByAppendingString:hash]];
}

- (void)requestList {
	type = T_LIST;
	needListUpdate = NO;
	[self sendNetworkRequest:@"?list=1"];
}

- (void)addTorrent:(NSString *)torrentURL {
	type = T_ADD;
	needListUpdate = YES;
	NSString * request = [[NSString alloc] initWithFormat:@"?action=add-url&s=%@", torrentURL];
	[self sendNetworkRequest:request];
	[request release];
}

- (void)addListener:(id<TorrentListener>)listener {
	[listeners addObject:listener];
}

- (void)removeListener:(id<TorrentListener>)listener {
	NSUInteger i, count = [listeners count];
	for (i = 0; i < count; i++) {
		NSObject * obj = [listeners objectAtIndex:i];
		if ([obj isEqual:listener]) {
			[listeners removeObjectAtIndex:i];
			break;
		}
	}
}

- (NSNumber *)updateUnlabelledTorrents {
	int ret = 0;
	int labelledItemCount = 0;
	for (NSArray * label in labelsData) {
		labelledItemCount += [[label objectAtIndex:1] intValue];
	}
	ret = [torrentsData count] - labelledItemCount;
	NSNumber * retObj = [[NSNumber alloc] initWithInt:ret];
	//self.unlabelledTorrents = retObj;
	return retObj;
}

- (void)dealloc {
	[unlabelledTorrents release];
	[torrentsCacheID release];
	[listeners release];
	[torrentsData release];
	[labelsData release];
	[removedTorrents release];
	[settingsAddress release];
	[settingsPort release];
	[settingsUname release];
	[settingsPassword release];
    [super dealloc];
}
@end
