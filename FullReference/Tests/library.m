#import <Foundation/Foundation.h>
#import "LXFullLibrary.h"
int main(void) { @autoreleasepool {
    NSURL *dir = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSURL *file = [dir URLByAppendingPathComponent:@"library.json"];
    LXFullLibrary *library = [[LXFullLibrary alloc] initWithURL:file];
    NSCAssert([library.snapshot[@"lists"] count] == 0, @"Cold offline library must open");
    NSMutableArray *songs = [NSMutableArray arrayWithObject:@{@"id": @"wy_10", @"name": @"歌曲"}];
    NSDictionary *value = @{@"lists": @[@{@"id": @"love", @"name": @"我的收藏", @"musics": songs}], @"recent": @[]};
    NSError *error;
    NSCAssert([library update:value error:&error], @"Cache update failed: %@", error);
    [songs removeAllObjects];
    NSCAssert([library.snapshot[@"lists"][0][@"musics"] count] == 1, @"Snapshot must detach from mutable bridge data");
    LXFullLibrary *restored = [[LXFullLibrary alloc] initWithURL:file];
    NSCAssert([restored.snapshot[@"lists"][0][@"musics"] count] == 1, @"Cold start lost persisted library");
    NSCAssert(![library update:@{@"lists": @"invalid"} error:&error], @"Reject malformed library");
    NSCAssert([library.snapshot[@"lists"][0][@"musics"] count] == 1, @"Invalid update must retain cached music");
    [library enqueue:@{@"type": @"refresh-library"}];
    [library enqueue:@{@"type": @"play", @"listId": @"love", @"musicId": @"wy_10"}];
    [library enqueue:@{@"type": @"play", @"listId": @"default", @"musicId": @"kg_10"}];
    NSArray *pending = [library drain];
    NSCAssert(pending.count == 1 && [pending[0][@"musicId"] isEqual:@"kg_10"], @"Only latest startup selection should play");
    NSCAssert([library drain].count == 0, @"Actions must not replay");
    [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
    puts("PASS: persisted full-library cache, detached snapshots, malformed-update protection and cold-start action delivery");
    return 0;
} }
