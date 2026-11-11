#import "IDPlatform.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/proc.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <unistd.h>

// Declared in the private <sys/codesign.h>; exported by libSystem.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define ID_CS_OPS_STATUS 0
#define ID_CS_OPS_ENTITLEMENTS_BLOB 7
#define ID_CS_DEBUGGED 0x10000000
// sys/posix_shm.h: longest POSIX shared memory name Darwin accepts.
#define ID_PSHMNAMLEN 31

@implementation IDPlatform

+ (BOOL)isDebuggerAttached {
    uint32_t flags = 0;
    if (csops(getpid(), ID_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return NO;
    return (flags & ID_CS_DEBUGGED) != 0;
}

+ (BOOL)isTraced {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return NO;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

+ (BOOL)needsTXMJITProtocol {
    return [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26, 0, 0}];
}

+ (uint64_t)availableMemory {
    return (uint64_t)os_proc_available_memory();
}

+ (uint64_t)physFootprint {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

+ (uint64_t)physicalMemory {
    return NSProcessInfo.processInfo.physicalMemory;
}

+ (NSString *)modelIdentifier {
    struct utsname u;
    if (uname(&u) != 0) return @"unknown";
    return [NSString stringWithUTF8String:u.machine];
}

+ (NSDictionary *)provisioningProfile {
    static NSDictionary *profile;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (!data) return;
        // The profile is a CMS envelope around a plain XML plist.
        NSData *start = [@"<?xml" dataUsingEncoding:NSASCIIStringEncoding];
        NSData *end = [@"</plist>" dataUsingEncoding:NSASCIIStringEncoding];
        NSRange a = [data rangeOfData:start options:0 range:NSMakeRange(0, data.length)];
        if (a.location == NSNotFound) return;
        NSRange b = [data rangeOfData:end options:0 range:NSMakeRange(a.location, data.length - a.location)];
        if (b.location == NSNotFound) return;
        NSData *plist = [data subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)];
        id obj = [NSPropertyListSerialization propertyListWithData:plist options:0 format:nil error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) profile = obj;
    });
    return profile;
}

+ (NSDictionary<NSString *, id> *)provisionedEntitlements {
    id e = [self provisioningProfile][@"Entitlements"];
    return [e isKindOfClass:NSDictionary.class] ? e : nil;
}

+ (NSDictionary<NSString *, id> *)signedEntitlements {
    static NSDictionary *entitlements;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The blob is {magic, length} (big endian) followed by an XML plist.
        // A too-small buffer fails with ERANGE but still gets the header.
        struct { uint32_t magic; uint32_t length; } header = {0, 0};
        csops(getpid(), ID_CS_OPS_ENTITLEMENTS_BLOB, &header, sizeof(header));
        uint32_t length = ntohl(header.length);
        if (ntohl(header.magic) != 0xfade7171 || length <= sizeof(header) || length > (1u << 20)) return;
        NSMutableData *blob = [NSMutableData dataWithLength:length];
        if (csops(getpid(), ID_CS_OPS_ENTITLEMENTS_BLOB, blob.mutableBytes, length) != 0) return;
        NSData *plist = [blob subdataWithRange:NSMakeRange(sizeof(header), length - sizeof(header))];
        id obj = [NSPropertyListSerialization propertyListWithData:plist options:0 format:nil error:nil];
        if ([obj isKindOfClass:NSDictionary.class]) entitlements = obj;
    });
    return entitlements;
}

static NSString *IDFirstGroup(NSDictionary *entitlements) {
    NSArray *groups = entitlements[@"com.apple.security.application-groups"];
    if ([groups isKindOfClass:NSArray.class] && groups.count > 0 && [groups.firstObject isKindOfClass:NSString.class]) {
        return groups.firstObject;
    }
    return nil;
}

+ (NSString *)applicationGroupIdentifier {
    NSDictionary *signedEnt = [self signedEntitlements];
    if (signedEnt) return IDFirstGroup(signedEnt); // authoritative, even when it has none
    NSString *group = IDFirstGroup([self provisionedEntitlements]);
    if (group) return group;
    // Fall back to the value baked into Info.plist at build time.
    NSString *fallback = NSBundle.mainBundle.infoDictionary[@"IDeckAppGroup"];
    return fallback.length ? fallback : nil;
}

+ (NSString *)applicationGroupSource {
    NSDictionary *signedEnt = [self signedEntitlements];
    if (signedEnt) return IDFirstGroup(signedEnt) ? @"signature" : @"none";
    if (IDFirstGroup([self provisionedEntitlements])) return @"profile";
    NSString *fallback = NSBundle.mainBundle.infoDictionary[@"IDeckAppGroup"];
    return fallback.length ? @"Info.plist" : @"none";
}

+ (NSArray<NSString *> *)applicationGroupCandidates {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    void (^addAll)(id) = ^(id groups) {
        if (![groups isKindOfClass:NSArray.class]) return;
        for (id g in groups) {
            if ([g isKindOfClass:NSString.class] && [g length] > 0 && ![out containsObject:g]) [out addObject:g];
        }
    };
    addAll([self signedEntitlements][@"com.apple.security.application-groups"]);
    addAll([self provisionedEntitlements][@"com.apple.security.application-groups"]);
    NSString *fallback = NSBundle.mainBundle.infoDictionary[@"IDeckAppGroup"];
    if (fallback.length) addAll(@[fallback]);
    return out;
}

+ (NSString *)sharedMemoryProblemForGroup:(NSString *)group {
    if (group.length == 0) return @"no app group in the code signature";
    // Same budget as virglrenderer's anon_file.c: "<group>/" + slot + nonce.
    if (group.length > ID_PSHMNAMLEN - 3) {
        return [NSString stringWithFormat:@"app group name is %lu characters; shared memory names allow at most %d",
                (unsigned long)group.length, ID_PSHMNAMLEN - 3];
    }
    NSString *name = [NSString stringWithFormat:@"%@/f%x", group, arc4random() >> 8];
    if (name.length > ID_PSHMNAMLEN) name = [name substringToIndex:ID_PSHMNAMLEN];
    int fd = shm_open(name.UTF8String, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0) return [NSString stringWithFormat:@"shm_open(\"%@\") failed: %s", name, strerror(errno)];
    shm_unlink(name.UTF8String);
    NSString *problem = nil;
    const size_t size = 64 * 1024;
    if (ftruncate(fd, (off_t)size) != 0) {
        problem = [NSString stringWithFormat:@"ftruncate on shared memory failed: %s", strerror(errno)];
    } else {
        void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (p == MAP_FAILED) {
            problem = [NSString stringWithFormat:@"mmap of shared memory failed: %s", strerror(errno)];
        } else {
            ((volatile char *)p)[0] = 1;
            munmap(p, size);
        }
    }
    close(fd);
    return problem;
}

+ (BOOL)hasIncreasedMemoryLimit {
    return [[self provisionedEntitlements][@"com.apple.developer.kernel.increased-memory-limit"] boolValue];
}

+ (NSString *)signingKind {
    NSDictionary *p = [self provisioningProfile];
    if (!p) return @"unsigned";
    NSDictionary *e = p[@"Entitlements"];
    if ([e[@"get-task-allow"] boolValue]) return @"development";
    if (p[@"ProvisionedDevices"]) return @"ad-hoc";
    return @"testflight/app-store";
}

@end
