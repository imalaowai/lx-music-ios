#import "LXFullLibrary.h"

NSString * const LXFullLibraryChanged = @"LXFullLibraryChanged";
NSString * const LXFullActionQueued = @"LXFullActionQueued";

@interface LXFullLibrary ()
@property(atomic, copy, readwrite) NSDictionary *snapshot;
@property(nonatomic, strong, readwrite) NSURL *fileURL;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *pending;
@end

@implementation LXFullLibrary
+ (instancetype)shared {
    static LXFullLibrary *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        #ifdef LX_OWN_UI
        library = [[self alloc] initWithURL:[base URLByAppendingPathComponent:@"LXMusic/CarPlay/own-library-v13.json"]];
        #else
        library = [[self alloc] initWithURL:[base URLByAppendingPathComponent:@"LXMusic/CarPlay/library-v12.json"]];
        #endif
    });
    return library;
}
- (instancetype)initWithURL:(NSURL *)url {
    if ((self = [super init])) {
        _fileURL = url; _pending = [NSMutableArray array];
        NSData *data = [NSData dataWithContentsOfURL:url];
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        _snapshot = [value isKindOfClass:NSDictionary.class] && [value[@"lists"] isKindOfClass:NSArray.class] ? value : @{@"lists": @[], @"recent": @[]};
    }
    return self;
}
- (BOOL)update:(NSDictionary *)value error:(NSError **)error {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"lists"] isKindOfClass:NSArray.class] || ![NSJSONSerialization isValidJSONObject:value]) {
        if (error) *error = [NSError errorWithDomain:@"LXFullLibrary" code:1 userInfo:@{NSLocalizedDescriptionKey: @"音乐库数据无效"}];
        return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:error];
    if (!data) return NO;
    // Detach nested mutable objects supplied by React Native before caching.
    NSDictionary *copy = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (!copy) return NO;
    @synchronized(self) { self.snapshot = copy; }
    [NSFileManager.defaultManager createDirectoryAtURL:self.fileURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL written = [data writeToURL:self.fileURL options:NSDataWritingAtomic error:error];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:LXFullLibraryChanged object:self]; });
    return written;
}
- (void)enqueue:(NSDictionary *)action {
    if (![action isKindOfClass:NSDictionary.class] || ![action[@"type"] isKindOfClass:NSString.class]) return;
    @synchronized(self) {
        // Multiple taps while the JS application is starting should play the latest selection.
        if ([action[@"type"] isEqual:@"play"]) [self.pending removeAllObjects];
        if (self.pending.count >= 32) [self.pending removeObjectAtIndex:0];
        [self.pending addObject:[action copy]];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:LXFullActionQueued object:self]; });
}
- (NSArray<NSDictionary *> *)drain {
    @synchronized(self) { NSArray *result = [self.pending copy]; [self.pending removeAllObjects]; return result; }
}
@end
