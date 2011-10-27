// SDURLCache.m
//
// Copyright (c) 2010-2011 Olivier Poitrey <rs@dailymotion.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is furnished
// to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "SDURLCache.h"
#import <NULevelDB/NULDBDB.h>
#import <CommonCrypto/CommonDigest.h>

#define kAFURLCachePath @"SDNetworkingURLCache"
#define kAFURLCacheMaintenanceTime 120ull

static NSTimeInterval const kAFURLCacheInfoDefaultMinCacheInterval = 5 * 60; // 5 minute

static NSString *kSDURLCacheDiskUsageKey = @"SDURLCache:capacity";

static NSString *kSDURLCacheMaintenanceSmallestKey = @"0000000000000000";
static NSString *kSDURLCacheMaintenanceTerminalKey = @"g";

static float const kAFURLCacheLastModFraction = 0.1f; // 10% since Last-Modified suggested by RFC2616 section 13.2.4
static float const kAFURLCacheDefault = 3600; // Default cache expiration delay if none defined (1 hour)

static NSDateFormatter* CreateDateFormatter(NSString *format) {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"] autorelease]];
    [dateFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]];
    [dateFormatter setDateFormat:format];
    return dateFormatter;
}


@implementation NSCachedURLResponse(NSCoder)

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeDataObject:self.data];
    [coder encodeObject:self.response forKey:@"response"];
    [coder encodeObject:self.userInfo forKey:@"userInfo"];
    [coder encodeInt:self.storagePolicy forKey:@"storagePolicy"];
}

- (id)initWithCoder:(NSCoder *)coder {
    return [self initWithResponse:[coder decodeObjectForKey:@"response"]
                             data:[coder decodeDataObject]
                         userInfo:[coder decodeObjectForKey:@"userInfo"]
                    storagePolicy:[coder decodeIntForKey:@"storagePolicy"]];
}

@end


@interface SDURLCache ()
@property (nonatomic, retain) NSString *diskCachePath;
@property (retain) SDURLCacheMaintenance *maintenance;
+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers withStatusCode:(NSInteger)status;
- (void)initializeMaintenance;
@end


@interface NSCachedURLResponse (SDURLCacheAdditions)
- (BOOL)isExpired:(NSTimeInterval)cacheInterval;
@end

@implementation NSCachedURLResponse (SDURLCacheAdditions)

- (BOOL)isExpired:(NSTimeInterval)cacheLimit {
    
    NSHTTPURLResponse *urlResponse = (NSHTTPURLResponse *)self.response;
    NSDictionary *headers = [urlResponse allHeaderFields];
    NSDate *expirationDate = [SDURLCache expirationDateFromHeaders:headers withStatusCode:urlResponse.statusCode];
        
    return [expirationDate timeIntervalSinceNow] - cacheLimit <= 0;
}

@end


@interface SDURLCacheMaintenance : NSObject {
    NSString *cursor;
    NSTimeInterval limit;
    BOOL paused;
    BOOL stop;
}

@property (retain) NSString *cursor;
@property (readwrite) NSTimeInterval limit;
@property (readwrite) BOOL paused;
@property (readwrite) BOOL stop;
@end

@implementation SDURLCacheMaintenance
@synthesize cursor, limit, paused, stop;
- (void)dealloc {
    self.cursor = nil;
    [super dealloc];
}
@end


@implementation SDURLCache

@synthesize maintenance;

#pragma mark SDURLCache (tools)

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    NSString *string = request.URL.absoluteString;
    NSRange hash = [string rangeOfString:@"#"];
    if (hash.location == NSNotFound)
        return request;
    
    NSMutableURLRequest *copy = [[request mutableCopy] autorelease];
    copy.URL = [NSURL URLWithString:[string substringToIndex:hash.location]];
    return copy;
}

+ (NSString *)cacheKeyForURL:(NSURL *)url {
    const char *str = [url.absoluteString UTF8String];
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, strlen(str), r);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];
}

#pragma mark SDURLCache (private)

/*
 * Parse HTTP Date: http://www.w3.org/Protocols/rfc2616/rfc2616-sec3.html#sec3.3.1
 */
+ (NSDate *)dateFromHttpDateString:(NSString *)httpDate {
    static dispatch_once_t onceToken;
    static dispatch_queue_t _dateFormatterQueue;
    static NSDateFormatter *_FC1123DateFormatter;
    static NSDateFormatter *_ANSICDateFormatter;
    static NSDateFormatter *_RFC850DateFormatter;
    dispatch_once(&onceToken, ^{
        _dateFormatterQueue = dispatch_queue_create("sdurlcache.dateformatter", NULL);
        _FC1123DateFormatter = CreateDateFormatter(@"EEE, dd MMM yyyy HH:mm:ss z");
        _ANSICDateFormatter = CreateDateFormatter(@"EEE MMM d HH:mm:ss yyyy");
        _RFC850DateFormatter = CreateDateFormatter(@"EEEE, dd-MMM-yy HH:mm:ss z");
    });
    
    __block NSDate *date = nil;
    dispatch_sync(_dateFormatterQueue, ^{
        date = [_FC1123DateFormatter dateFromString:httpDate];
        if (!date) {
            // ANSI C date format - Sun Nov  6 08:49:37 1994
            date = [_ANSICDateFormatter dateFromString:httpDate];
            if (!date) {
                // RFC 850 date format - Sunday, 06-Nov-94 08:49:37 GMT
                date = [_RFC850DateFormatter dateFromString:httpDate];
            }
        }        
    });
    
    return date;
}

/*
 * This method tries to determine the expiration date based on a response headers dictionary.
 */
+ (NSDate *)expirationDateFromHeaders:(NSDictionary *)headers withStatusCode:(NSInteger)status {
    if (status != 200 && status != 203 && status != 300 && status != 301 && status != 302 && status != 307 && status != 410) {
        // Uncacheable response status code
        return nil;
    }
    
    // Check Pragma: no-cache
    NSString *pragma = [headers objectForKey:@"Pragma"];
    if (pragma && [pragma isEqualToString:@"no-cache"]) {
        // Uncacheable response
        return nil;
    }
    
    // Define "now" based on the request
    NSString *date = [headers objectForKey:@"Date"];
    // If no Date: header, define now from local clock
    NSDate *now = date ? [SDURLCache dateFromHttpDateString:date] : [NSDate date];
    
    // Look at info from the Cache-Control: max-age=n header
    NSString *cacheControl = [headers objectForKey:@"Cache-Control"];
    if (cacheControl) {
        NSRange foundRange = [cacheControl rangeOfString:@"no-store"];
        if (foundRange.length > 0) {
            // Can't be cached
            return nil;
        }
        
        NSInteger maxAge;
        foundRange = [cacheControl rangeOfString:@"max-age="];
        if (foundRange.length > 0) {
            NSScanner *cacheControlScanner = [NSScanner scannerWithString:cacheControl];
            [cacheControlScanner setScanLocation:foundRange.location + foundRange.length];
            if ([cacheControlScanner scanInteger:&maxAge]) {
                return maxAge > 0 ? [[[NSDate alloc] initWithTimeInterval:maxAge sinceDate:now] autorelease] : nil;
            }
        }
    }
    
    // If not Cache-Control found, look at the Expires header
    NSString *expires = [headers objectForKey:@"Expires"];
    if (expires) {
        NSTimeInterval expirationInterval = 0;
        NSDate *expirationDate = [SDURLCache dateFromHttpDateString:expires];
        if (expirationDate) {
            expirationInterval = [expirationDate timeIntervalSinceDate:now];
        }
        if (expirationInterval > 0) {
            // Convert remote expiration date to local expiration date
            return [NSDate dateWithTimeIntervalSinceNow:expirationInterval];
        }
        else {
            // If the Expires header can't be parsed or is expired, do not cache
            return nil;
        }
    }
    
    if (status == 302 || status == 307) {
        // If not explict cache control defined, do not cache those status
        return nil;
    }
    
    // If no cache control defined, try some heristic to determine an expiration date
    NSString *lastModified = [headers objectForKey:@"Last-Modified"];
    if (lastModified) {
        NSTimeInterval age = 0;
        NSDate *lastModifiedDate = [SDURLCache dateFromHttpDateString:lastModified];
        if (lastModifiedDate) {
            // Define the age of the document by comparing the Date header with the Last-Modified header
            age = [now timeIntervalSinceDate:lastModifiedDate];
        }
        return age > 0 ? [NSDate dateWithTimeIntervalSinceNow:(age * kAFURLCacheLastModFraction)] : nil;
    }
    
    // If nothing permitted to define the cache expiration delay nor to restrict its cacheability, use a default cache expiration delay
    return [[[NSDate alloc] initWithTimeInterval:kAFURLCacheDefault sinceDate:now] autorelease];
}


#define INTERRUPT_CHECK_INTERVAL 128

static void SDMaintainCache(NULDBDB *cacheDB, SDURLCacheMaintenance *maintenance) {
    
    NSLog(@"Started maintenance with key '%@'", maintenance.cursor);
    
    __block BOOL interrupted = NO;
    __block NSUInteger interruptCheckCounter = 0;
    
    BOOL(^block)(NSString *key, NSData *value) = ^BOOL(NSString *key, NSData *value){
        
        // Quick way to tell the key doesn't refer to a cached response
        if([key length] != 32) return YES;
        
        
        NSCachedURLResponse *response = [NSKeyedUnarchiver unarchiveObjectWithData:value];
        
        if(![response isKindOfClass:[NSCachedURLResponse class]]) return YES;
        
        if([response isExpired:maintenance.limit]) {
            NSLog(@"Evicting '%@' for being too old.", response.response.URL);
            NSError *error = nil;
            if(![cacheDB deleteStoredDataForKey:key error:&error])
                NSLog(@"Error deleting key '%@': %@", key, error);
        }
        
        if(0 == interruptCheckCounter++%INTERRUPT_CHECK_INTERVAL && maintenance.stop) {
            interrupted = YES;
            maintenance.cursor = key;
            return NO;
        }
        
        return YES;
    };
    
    [cacheDB iterateFromKey:maintenance.cursor toKey:kSDURLCacheMaintenanceTerminalKey block:block];
    
    if(!interrupted)
        maintenance.cursor = kSDURLCacheMaintenanceSmallestKey;
    
    NSLog(@"Finished maintenance with key '%@' (checked %u keys)", interrupted ? maintenance.cursor : kSDURLCacheMaintenanceTerminalKey, interruptCheckCounter);
}

- (void)initializeMaintenance {
    
    self.maintenance = [[[SDURLCacheMaintenance alloc] init] autorelease];
    self.maintenance.cursor = kSDURLCacheMaintenanceSmallestKey;
    self.maintenance.limit = _minCacheInterval;

    _maintenanceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _maintenanceQueue);
    
    if (_maintenanceTimer) {
        dispatch_source_set_timer(_maintenanceTimer, dispatch_walltime(DISPATCH_TIME_NOW, kAFURLCacheMaintenanceTime * NSEC_PER_SEC), 
                                  kAFURLCacheMaintenanceTime * NSEC_PER_SEC, kAFURLCacheMaintenanceTime/2 * NSEC_PER_SEC);

        dispatch_source_set_event_handler(_maintenanceTimer, ^{
            
            dispatch_async(dispatch_get_main_queue(), ^{
                dispatch_suspend(_maintenanceTimer); // pause timer
                maintenance.paused = YES;
            });
            
            SDMaintainCache(db, maintenance);
        });
        
        // initially wake up timer
        dispatch_resume(_maintenanceTimer);
    }
}

- (void)storeRequestToDisk:(NSURLRequest *)request response:(__block NSCachedURLResponse *)cachedResponse {
    
    dispatch_async(_diskCacheQueue, ^{
        
        NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:cachedResponse];
        NSError *error = nil;
        
        if(![db storeData:data forKey:cacheKey error:&error])
            NSLog(@"Error storing response: %@", error);
        
        if(self.maintenance.paused) {
            dispatch_resume(_maintenanceTimer);
            self.maintenance.paused = NO;
        }
    });
}


#pragma mark SDURLCache

+ (NSString *)defaultCachePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:kAFURLCachePath];
}

#pragma mark NSURLCache

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity diskPath:(NSString *)path {
    
    self = [super initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity diskPath:path];
    
    if (self) {
        
        _minCacheInterval = kAFURLCacheInfoDefaultMinCacheInterval;
        _ignoreMemoryOnlyStoragePolicy = YES;
        _diskCacheQueue = dispatch_queue_create("sdurlcache.processing", NULL);
        self.diskCachePath = path;
        
        db = [[NULDBDB alloc] initWithLocation:path];
        
        NSError *error = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:[NSNumber numberWithUnsignedInteger:diskCapacity]];
        
        if(![db storeData:data forKey:kSDURLCacheDiskUsageKey error:&error]) {
            NSLog(@"NULevelDB error inserting key '%@': %@", kSDURLCacheDiskUsageKey, error);
        }
        
        [self initializeMaintenance];
	}
    
    return self;
}

- (void)storeCachedResponse:(NSCachedURLResponse *)cachedResponse forRequest:(NSURLRequest *)request {
    request = [SDURLCache canonicalRequestForRequest:request];
    
    if (request.cachePolicy == NSURLRequestReloadIgnoringLocalCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringLocalAndRemoteCacheData
        || request.cachePolicy == NSURLRequestReloadIgnoringCacheData) {
        // When cache is ignored for read, it's a good idea not to store the result as well as this option
        // have big chance to be used every times in the future for the same request.
        // NOTE: This is a change regarding default URLCache behavior
        return;
    }
    
    [super storeCachedResponse:cachedResponse forRequest:request];
    
    NSURLCacheStoragePolicy storagePolicy = cachedResponse.storagePolicy;
    
    if ((storagePolicy == NSURLCacheStorageAllowed || (storagePolicy == NSURLCacheStorageAllowedInMemoryOnly && _ignoreMemoryOnlyStoragePolicy))
        && [cachedResponse.response isKindOfClass:[NSHTTPURLResponse self]]
        && cachedResponse.data.length < self.diskCapacity) {
        
        NSDictionary *headers = [(NSHTTPURLResponse *)cachedResponse.response allHeaderFields];
        
        // RFC 2616 section 13.3.4 says clients MUST use Etag in any cache-conditional request if provided by server
        if (![headers objectForKey:@"Etag"]) {
            
            NSDate *expirationDate = [SDURLCache expirationDateFromHeaders:headers
                                                            withStatusCode:((NSHTTPURLResponse *)cachedResponse.response).statusCode];
            
            if (!expirationDate || [expirationDate timeIntervalSinceNow] - _minCacheInterval <= 0) {
                // This response is not cacheable, headers said
                return;
            }
        }
        
        [self storeRequestToDisk:request response:cachedResponse];
    }
}

- (NSCachedURLResponse *)cachedResponseForRequest:(NSURLRequest *)request {
    
    request = [SDURLCache canonicalRequestForRequest:request];
    
    NSCachedURLResponse *response = [super cachedResponseForRequest:request];

    if (!response) {
        
        NSString *cacheKey = [SDURLCache cacheKeyForURL:request.URL];
        NSError *error = nil;
        
        NSData *data = [db storedDataForKey:cacheKey error:&error];
        
        if(nil != data)
            response = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        else if(nil != error)
            NSLog(@"Error storing data for key '%@': %@", cacheKey, error);
        
        if (nil != response)
            [super storeCachedResponse:response forRequest:request];
    }
    
    return response;
}

- (void)removeCachedResponseForRequest:(NSURLRequest *)request {
    request = [SDURLCache canonicalRequestForRequest:request];
    
    [super removeCachedResponseForRequest:request];

    dispatch_async(_diskCacheQueue, ^{

        NSError *error = nil;

        if(![db deleteStoredDataForKey:[SDURLCache cacheKeyForURL:request.URL] error:&error])
            NSLog(@"Error deleting cached value: %@", error);
    });
}

- (void)removeAllCachedResponses {
    [super removeAllCachedResponses];
    [db destroy];
    [db release];
    db = [[NULDBDB alloc] initWithLocation:self.diskCachePath];
}

- (BOOL)isCached:(NSURL *)url {
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    request = [SDURLCache canonicalRequestForRequest:request];
    
    if ([super cachedResponseForRequest:request]) {
        return YES;
    }
    NSString *cacheKey = [SDURLCache cacheKeyForURL:url];
    
    return [db storedDataExistsForKey:cacheKey];
}

#pragma mark NSObject

- (void)dealloc {
    self.maintenance.stop = YES;
    self.maintenance = nil;
    if(NULL != _maintenanceTimer) {
        dispatch_source_cancel(_maintenanceTimer);
        dispatch_release(_maintenanceTimer), _maintenanceTimer = NULL;
    }
    if(NULL != _maintenanceQueue)
        dispatch_release(_maintenanceQueue), _diskCacheQueue = NULL;
    if(NULL != _diskCacheQueue)
        dispatch_release(_diskCacheQueue), _diskCacheQueue = NULL;
    [_diskCachePath release], _diskCachePath = nil;
    [db release], db = nil;
    [super dealloc];
}

@synthesize minCacheInterval = _minCacheInterval;
@synthesize ignoreMemoryOnlyStoragePolicy = _ignoreMemoryOnlyStoragePolicy;
@synthesize diskCachePath = _diskCachePath;

@end
