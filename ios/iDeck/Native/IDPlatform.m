#import "IDPlatform.h"

#import <mach/mach.h>
#import <os/proc.h>
#import <sys/proc.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <unistd.h>

// Declared in the private <sys/codesign.h>; exported by libSystem.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define ID_CS_OPS_STATUS 0
#define ID_CS_DEBUGGED 0x10000000

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

+ (NSString *)applicationGroupIdentifier {
    NSArray *groups = [self provisionedEntitlements][@"com.apple.security.application-groups"];
    if ([groups isKindOfClass:NSArray.class] && groups.count > 0 && [groups.firstObject isKindOfClass:NSString.class]) {
        return groups.firstObject;
    }
    // Fall back to the value baked into Info.plist at build time.
    NSString *fallback = NSBundle.mainBundle.infoDictionary[@"IDeckAppGroup"];
    return fallback.length ? fallback : nil;
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
