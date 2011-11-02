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


/* Conditional support for the DDLog* macros from the Lumberjack logging framework.
 * Add the Lumberjack files to your project and add #import "DDLog.h" to your pre-compiled header
 */

#ifndef DDLogVerbose
#define DDLogError    NSLog
#ifdef DEBUG
#define DDLogVerbose NSLog
#define DDLogCVerbose NSLog
#else
#define DDLogVerbose(...)
#define DDLogCVerbose(...)
#endif
#else
static const int ddLogLevel = LOG_LEVEL_VERBOSE;
#endif

#define NUMLoc()         DDLogVerbose(@"[%@:%@] %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd), self)



#define kAFURLCachePath @"SDNetworkingURLCache"
#define kAFURLCacheMaintenanceTime 20ull

static NSTimeInterval const kAFURLCacheInfoDefaultMinCacheInterval = 5 * 60; // 5 minute

static NSString *kSDURLCacheDiskUsageKey    = @"SDURLCache:capacity";
static NSString *kSDURLCacheMainPageURLKey  = @"SDURLCache:mainPageURL";

static NSString *kSDURLCacheMaintenanceSmallestKey = @"0000000000000000";
static NSString *kSDURLCacheMaintenanceTerminalKey = @"g";

static float const kAFURLCacheLastModFraction = 0.1f; // 10% since Last-Modified suggested by RFC2616 section 13.2.4
static float const kAFURLCacheDefault         = 3600; // Default cache expiration delay if none defined (1 hour)



static void SDMaintainCache(NULDBDB *cacheDB, SDURLCacheMaintenance *maintenance);


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
+ (NSString *)cacheKeyForURL:(NSURL *)url;
- (void)initializeMaintenance;
@end


@interface NSCachedURLResponse (SDURLCacheAdditions)
- (BOOL)isExpired:(NSDate **)expiration;
@end

@implementation NSCachedURLResponse (SDURLCacheAdditions)

- (BOOL)isExpired:(NSDate **)expiration {
    
    NSHTTPURLResponse *urlResponse = (NSHTTPURLResponse *)self.response;
    NSDictionary *headers = [urlResponse allHeaderFields];
    NSDate *expirationDate = [SDURLCache expirationDateFromHeaders:headers withStatusCode:urlResponse.statusCode];
    
    if(expiration)
        *expiration = expirationDate;
        
    return [expirationDate timeIntervalSinceNow] <= 0;
}

@end


@interface NULDBDB (SDURLCacheAdditions)

- (void)storeCachedURLResponse:(NSCachedURLResponse *)cachedResponse forKey:(NSString *)key;
- (NSCachedURLResponse *)cachedURLResponseForKey:(NSString *)key;
- (void)deleteCachedURLResponseForKey:(NSString *)key;

@end

@implementation NULDBDB (SDURLCacheAdditions)

#define SDURLLastModifiedKeyForCacheKey(_key_) ([NSString stringWithFormat:@"$SDURLLastModified:%@", _key_])

// These methods store the last modified date for the response in a separate db entry
// They *don't* store the last modified date for the main Page URL, if it exists
// thus, the main page URL will not ever be flushed from the cache
// If necessary, we could keep an array of URLs which are meant to be ignored during cache flushes
- (void)storeCachedURLResponse:(NSCachedURLResponse *)cachedResponse forKey:(NSString *)key {
    
    NSError *error = nil;
    NSString *mainPageKey = [self storedStringForKey:kSDURLCacheMainPageURLKey error:NULL];
    
    if(![mainPageKey isEqual:key]) {
        NSString *lastAccessedKey = SDURLLastModifiedKeyForCacheKey(key);
        
        if(![self storeData:[NSKeyedArchiver archivedDataWithRootObject:[NSDate date]] forKey:lastAccessedKey error:&error])
            DDLogError(@"Error storing last modified key '%@': %@", lastAccessedKey, error);
        
        error = nil;
    }

    if(![self storeData:[NSKeyedArchiver archivedDataWithRootObject:cachedResponse] forKey:key error:&error])
        DDLogError(@"Error storing cached URL response for key '%@': %@", key, error);
}


- (NSCachedURLResponse *)cachedURLResponseForKey:(NSString *)key {
    
    NSError *error = nil;
    NSData *data = [self storedDataForKey:key error:&error];

    if(nil == data) {
        if( nil != error)
            DDLogError(@"Error storing data for key '%@': %@", key, error);
        return nil;
    }

    NSString *mainPageKey = [self storedStringForKey:kSDURLCacheMainPageURLKey error:NULL];
    
    if(![mainPageKey isEqual:key]) {
        NSString *lastAccessedKey = SDURLLastModifiedKeyForCacheKey(key);
        
        if(![self storeData:[NSKeyedArchiver archivedDataWithRootObject:[NSDate date]] forKey:lastAccessedKey error:&error])
            DDLogError(@"Error storing last modified key '%@': %@", lastAccessedKey, error);
        
        error = nil;
    }

    return [NSKeyedUnarchiver unarchiveObjectWithData:data];
}

- (void)deleteCachedURLResponseForKey:(NSString *)key {
    
    NSError *error = nil;    
    NSString *mainPageKey = [self storedStringForKey:kSDURLCacheMainPageURLKey error:NULL];
    
    if(![mainPageKey isEqual:key]) {
        NSString *lastAccesedKey = SDURLLastModifiedKeyForCacheKey(key);
        
        if(![self deleteStoredDataForKey:lastAccesedKey error:&error])
            DDLogError(@"Error deleting last modified key '%@': %@", lastAccesedKey, error);
        
        error = nil;
    }
    
    if(![self deleteStoredDataForKey:key error:&error])
        DDLogError(@"Error deleting cached URL response for key '%@': %@", key, error);   
}

- (void)deleteCachedURLResponsesForKeys:(NSArray *)keys {
    NSError *error = nil;
    if(![self deleteStoredStringsForKeys:keys error:&error])
        DDLogError(@"Error bulk deleting cached URL responses: %@", error);
}

@end


#pragma mark - SDURLCacheMaintenance
@interface SDURLCacheMaintenance : NSObject {
    
    NULDBDB *db;
    
    NSString *cursor;

    dispatch_queue_t _maintenanceQueue;
    dispatch_source_t _maintenanceTimer;
    dispatch_group_t _maintenanceGroup;
    
    NSUInteger sizeLimit;
    BOOL paused;
    BOOL stop;
}

@property (retain) NSString *cursor;
@property (readwrite) NSUInteger sizeLimit;
@property (readwrite) BOOL paused;
@property (readwrite) BOOL stop;

- (void)pause;
- (void)resume;
- (void)stopMaintenanceQueue;

@end

@implementation SDURLCacheMaintenance

@synthesize cursor, sizeLimit, paused, stop;

- (void)dealloc {
    [db release], db = nil;
    self.cursor = nil;
    [self stopMaintenanceQueue];
    [super dealloc];
}

- (id)initWithDatabase:(NULDBDB *)database {
    self = [super init];
    if(self) {
        db = [database retain];
        _maintenanceQueue = dispatch_queue_create("sdurlcache.maintenance", NULL);
        _maintenanceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _maintenanceQueue);
        _maintenanceGroup = dispatch_group_create();

        if (_maintenanceTimer) {
            dispatch_source_set_timer(_maintenanceTimer, dispatch_walltime(DISPATCH_TIME_NOW, kAFURLCacheMaintenanceTime * NSEC_PER_SEC), 
                                      kAFURLCacheMaintenanceTime * NSEC_PER_SEC, kAFURLCacheMaintenanceTime/2 * NSEC_PER_SEC);
            
            dispatch_source_set_event_handler(_maintenanceTimer, ^{ SDMaintainCache(db, self); });
            
            dispatch_resume(_maintenanceTimer);
        }
    }
    
    return self;
}

- (void)runNow {
    dispatch_async(_maintenanceQueue, ^{
        dispatch_group_enter(_maintenanceGroup);
        SDMaintainCache(db, self);
        dispatch_group_leave(_maintenanceGroup);
    });
}

- (void)pause {
    dispatch_async(dispatch_get_main_queue(), ^{
        
        if(self.paused) return;
        
        dispatch_suspend(_maintenanceTimer);
        self.paused = YES;
    });
}

- (void)resume {
    dispatch_async(dispatch_get_main_queue(), ^{
        
        if(!self.paused) return;
        
        dispatch_resume(_maintenanceTimer);
        self.paused = NO;
    });
}

- (void)stopMaintenanceQueue {
    if(NULL != _maintenanceTimer) {
        dispatch_source_cancel(_maintenanceTimer);
        dispatch_release(_maintenanceTimer), _maintenanceTimer = NULL;
    }
    if(NULL != _maintenanceQueue)
        dispatch_release(_maintenanceQueue), _maintenanceQueue = NULL;
    if(NULL != _maintenanceGroup)
        dispatch_release(_maintenanceGroup), _maintenanceGroup = NULL;
}

- (void)synchronizeAndStop {
    stop = YES;
    dispatch_group_wait(_maintenanceGroup, DISPATCH_TIME_FOREVER);
    [self stopMaintenanceQueue];
}

@end


@interface SDURLResponseUsageInfo : NSObject {
    NSString *key;
    NSDate *lastAccessed;
@public
    NSUInteger size;
}
@property (nonatomic, retain) NSString *key;
@property (nonatomic, retain) NSDate *lastAccessed;
@end


@implementation SDURLResponseUsageInfo
@synthesize key, lastAccessed;
@end


#pragma mark - SDURLCache
@implementation SDURLCache

#pragma mark - Accessors
- (void)setOffline:(BOOL)flag {
    _offline = flag;
    if(flag)
        [maintenance pause];
    maintenance.stop = flag;
}

- (void)setMainPageURL:(NSURL *)aURL {
    if(![_mainPageURL isEqual:aURL]) {
        [_mainPageURL release];
        _mainPageURL = [aURL retain];
        if(_mainPageURL) {
            dispatch_async(_diskCacheQueue, ^{
                [db storeString:[[self class] cacheKeyForURL:_mainPageURL] forKey:kSDURLCacheMainPageURLKey error:NULL];
                [db deleteStoredDataForKey:[[self class] cacheKeyForURL:_mainPageURL] error:NULL];
            });
        }
        else
            dispatch_async(_diskCacheQueue, ^{ [db deleteStoredDataForKey:kSDURLCacheMainPageURLKey error:NULL]; });
    }
}


#pragma mark - SDURLCache (tools)

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


#define SIZE_TOLERANCE_FACTOR 1.5f

static void SDMaintainCache(NULDBDB *cacheDB, SDURLCacheMaintenance *maintenance) {
    
    NSUInteger cacheSize = [cacheDB currentSizeEstimate];
    NSMutableArray *evictionCandidates = maintenance.sizeLimit > 0 ? [NSMutableArray arrayWithCapacity:128] : nil;
    __block NSUInteger candidatesTotalSize = 0;
    __block NSUInteger counter = 0;
    
    // The size of the cache reported by leveldb is always way behind the actual size
    // To dampen the effect of this, we only flush if we're sufficiently over-size, and we only remove 25% of the difference
    NSUInteger sizeOverage = cacheSize > maintenance.sizeLimit ? cacheSize - maintenance.sizeLimit : 0;

    if (sizeOverage < maintenance.sizeLimit / 8)
        sizeOverage = 0;
    else
        sizeOverage /= 2;
    
    DDLogCVerbose(@"Started maintenance with key '%@'. Approximate cache size: %u bytes.", maintenance.cursor, cacheSize);

    BOOL(^block)(NSString *key, NSData *value) = ^BOOL(NSString *key, NSData *value) {
        
        // Quick way to tell the key doesn't refer to a cached response
        if([key length] != 32) return YES;
        
        
        NSCachedURLResponse *response = [NSKeyedUnarchiver unarchiveObjectWithData:value];
        
        if(![response isKindOfClass:[NSCachedURLResponse class]]) return YES;
        
        NSData *lastAccessData = [cacheDB storedDataForKey:SDURLLastModifiedKeyForCacheKey(key) error:NULL];
        NSDate *lastAccessedDate = lastAccessData ? [NSKeyedUnarchiver unarchiveObjectWithData:lastAccessData] : nil;
        
        if([response isExpired:NULL]) {
            DDLogCVerbose(@"Evicting '%@' for being too old.", response.response.URL);
            [cacheDB deleteCachedURLResponseForKey:key];
        }
        else if(sizeOverage > 0 && nil != lastAccessedDate) {
            
            SDURLResponseUsageInfo *usageInfo = [[SDURLResponseUsageInfo alloc] init];
            
            usageInfo.key = key;
            usageInfo.lastAccessed = lastAccessedDate;

            // If the index is low, this is an old object; if it's high (close to [evictionCandidates count], this is a new object
            NSUInteger index = [evictionCandidates indexOfObject:usageInfo
                                                   inSortedRange:NSMakeRange(0, [evictionCandidates count])
                                                         options:NSBinarySearchingFirstEqual|NSBinarySearchingInsertionIndex
                                                 usingComparator:^(SDURLResponseUsageInfo *obj1, SDURLResponseUsageInfo *obj2) {
                                                     return [obj1.lastAccessed compare:obj2.lastAccessed];
                                                 }];
            
            NSUInteger entrySize = [cacheDB sizeUsedByKey:key];

            // If the entry size is zero, it's a new entry, so skip
            // If we've already got enough candidates and this guy isn't older than any existing candidates, skip
            if(entrySize > 0 && (index < [evictionCandidates count] || candidatesTotalSize < sizeOverage)) {
                
                candidatesTotalSize += usageInfo->size = entrySize;

                [evictionCandidates insertObject:usageInfo atIndex:index];
                
                if(candidatesTotalSize > sizeOverage) {
                    
                    SDURLResponseUsageInfo *pardoned = [evictionCandidates lastObject];
                    
                    [evictionCandidates removeLastObject];
                    candidatesTotalSize -= pardoned->size;
                }
            }
            
            [usageInfo release];
        }
        
        ++counter;
        
        if(maintenance.stop) {
            DDLogCVerbose(@"Stop flag is set; terminating early.");
            maintenance.cursor = key;
            return NO;
        }
        
        return YES;
    };
    
    [cacheDB iterateFromKey:maintenance.cursor toKey:kSDURLCacheMaintenanceTerminalKey block:block];
    
    
    if(!maintenance.stop) {
        
        NSDate *youngest = [[evictionCandidates lastObject] lastAccessed];
        
        if([evictionCandidates count]) {
            
            NSUInteger oldSize = cacheSize;
            NSUInteger newSize = oldSize > candidatesTotalSize ? oldSize - candidatesTotalSize : 0;
            
            DDLogCVerbose(@"Deleting %d entries to reduce cache size (was %u bytes; will be %u bytes). Youngest: %@", [evictionCandidates count], oldSize, newSize, youngest);
            [cacheDB deleteCachedURLResponsesForKeys:[evictionCandidates valueForKey:@"key"]];
        }
        
        maintenance.cursor = kSDURLCacheMaintenanceSmallestKey;
    }
    
    DDLogCVerbose(@"Finished maintenance with key '%@' (checked %u keys)", maintenance.stop ? maintenance.cursor : kSDURLCacheMaintenanceTerminalKey, counter);
}

- (void)initializeMaintenance {
    
    self.maintenance = [[[SDURLCacheMaintenance alloc] initWithDatabase:db] autorelease];
    
    self.maintenance.cursor = kSDURLCacheMaintenanceSmallestKey;
    self.maintenance.sizeLimit = self.diskCapacity;
    
    [self.maintenance runNow];
}

- (void)storeRequestToDisk:(NSURLRequest *)request response:(NSCachedURLResponse *)cachedResponse {
    
    dispatch_async(_diskCacheQueue, ^{

        [db storeCachedURLResponse:cachedResponse forKey:[SDURLCache cacheKeyForURL:request.URL]];
        
        if(!_offline) [maintenance resume];
    });
}


#pragma mark - Accessors


#pragma mark - SDURLCache

+ (NSString *)defaultCachePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:kAFURLCachePath];
}

#pragma mark - NSURLCache

- (id)initWithMemoryCapacity:(NSUInteger)memoryCapacity diskCapacity:(NSUInteger)diskCapacity diskPath:(NSString *)path {
    
    self = [super initWithMemoryCapacity:memoryCapacity diskCapacity:diskCapacity diskPath:path];
    
    if (self) {
        
        _minCacheInterval = kAFURLCacheInfoDefaultMinCacheInterval;
        _ignoreMemoryOnlyStoragePolicy = YES;
        _diskCacheQueue = dispatch_queue_create("sdurlcache.processing", NULL);
        self.diskCachePath = path;
        
        db = [[NULDBDB alloc] initWithLocation:path bufferSize:diskCapacity > 1<<24 ? 1<<22 : diskCapacity / 4];
                
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

        response = [db cachedURLResponseForKey:cacheKey];
        
        if(!self.offline && [response isExpired:NULL]) {
            dispatch_async(_diskCacheQueue, ^{ [db deleteCachedURLResponseForKey:cacheKey]; });
            response = nil;
        }
        
        if (nil != response)
            [super storeCachedResponse:response forRequest:request];
    }
    
    return response;
}

- (void)removeCachedResponseForRequest:(NSURLRequest *)request {
    request = [SDURLCache canonicalRequestForRequest:request];
    
    [super removeCachedResponseForRequest:request];

    dispatch_async(_diskCacheQueue, ^{ [db deleteCachedURLResponseForKey:[SDURLCache cacheKeyForURL:request.URL]]; });
}

- (void)removeAllCachedResponses {
    
    DDLogVerbose(@"Stopping maintenance and resetting database.");

    [super removeAllCachedResponses];
    
    /* Replace the existing database with a new empty one. We do this on the cache queue to interleave with cache writes.
     * We release our reference to the existing db to prevent reads from starting on the db that is going away. The maintenance
     * task has its own retained reference.
     *
     * The steps in the following block are important.
     * 1. Stop the maintenance task. This will free up the block which holds the maintenance object, reducing its retain count.
     * 2. Release the old database. Nothing else will try to access it at this point.
     * 3. Destroy the old database.
     * 4. Create the new database.
     * 5. Reset the maintenance task; this releases the old maintenance and the old database.
     *
     */
    
    [db release], db = nil;

    dispatch_async(_diskCacheQueue, ^{
        [maintenance synchronizeAndStop];
        self.maintenance = nil;
        [NULDBDB destroyDatabase:self.diskCachePath];
        db = [[NULDBDB alloc] initWithLocation:self.diskCachePath];
        [self initializeMaintenance];
        DDLogVerbose(@"Cache database has been reset.");
    });
}

- (BOOL)isCached:(NSURL *)url {
    
    if ([super cachedResponseForRequest:[SDURLCache canonicalRequestForRequest:[NSURLRequest requestWithURL:url]]])
        return YES;
    
    return [db storedDataExistsForKey:[SDURLCache cacheKeyForURL:url]];
}

#pragma mark - NSObject

- (void)dealloc {
    self.maintenance.stop = YES;
    self.maintenance = nil;
    self.mainPageURL = nil;
    if(NULL != _diskCacheQueue)
        dispatch_release(_diskCacheQueue), _diskCacheQueue = NULL;
    [_diskCachePath release], _diskCachePath = nil;
    [db release], db = nil;
    [super dealloc];
}

@synthesize maintenance;
@synthesize minCacheInterval = _minCacheInterval;
@synthesize ignoreMemoryOnlyStoragePolicy = _ignoreMemoryOnlyStoragePolicy;
@synthesize diskCachePath = _diskCachePath;
@synthesize offline = _offline;
@synthesize mainPageURL = _mainPageURL;

@end
