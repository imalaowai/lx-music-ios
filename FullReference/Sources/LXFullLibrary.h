#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const LXFullLibraryChanged;
FOUNDATION_EXPORT NSString * const LXFullActionQueued;

@interface LXFullLibrary : NSObject
@property(atomic, copy, readonly) NSDictionary *snapshot;
@property(nonatomic, strong, readonly) NSURL *fileURL;
- (instancetype)initWithURL:(NSURL *)url;
+ (instancetype)shared;
- (BOOL)update:(NSDictionary *)value error:(NSError **)error;
- (void)enqueue:(NSDictionary *)action;
- (NSArray<NSDictionary *> *)drain;
@end
