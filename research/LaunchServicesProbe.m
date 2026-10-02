#import <AppKit/AppKit.h>
#import <dlfcn.h>

// Investigation only: mutations are restricted to our disposable test app.
typedef OSStatus (*SetItem)(int, CFTypeRef, CFStringRef, CFTypeRef, CFDictionaryRef *);
typedef CFTypeRef (*CopyItem)(int, CFTypeRef, CFTypeRef);

@interface NSRunningApplication (ProbeSPI)
- (CFTypeRef)applicationSerialNumber;
@end

static CFStringRef symbolString(const char *name) {
    CFStringRef *value = dlsym(RTLD_DEFAULT, name);
    return value ? *value : NULL;
}

static int probe(pid_t pid) {
    NSApplication *controller = [NSApplication sharedApplication];
    [controller setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [controller finishLaunching];
    NSRunningApplication *target = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!target || ![target.bundleIdentifier isEqualToString:@"local.cmdtabo.LaunchServicesProbe"]) {
        fprintf(stderr, "Refusing: target must be our disposable test app.\n");
        return 2;
    }
    SetItem setItem = (SetItem)dlsym(RTLD_DEFAULT, "_LSSetApplicationInformationItem");
    CopyItem copyItem = (CopyItem)dlsym(RTLD_DEFAULT, "_LSCopyApplicationInformationItem");
    CFStringRef key = symbolString("_kLSApplicationTypeKey");
    CFStringRef ui = symbolString("_kLSApplicationUIElementTypeKey");
    CFStringRef foreground = symbolString("_kLSApplicationForegroundTypeKey");
    printf("symbols: set=%d copy=%d type=%d ui=%d foreground=%d asnSelector=%d\n",
           setItem != NULL, copyItem != NULL, key != NULL, ui != NULL,
           foreground != NULL, [target respondsToSelector:@selector(applicationSerialNumber)]);
    if (!setItem || !copyItem || !key || !ui || !foreground ||
        ![target respondsToSelector:@selector(applicationSerialNumber)]) return 3;
    CFTypeRef asn = [target applicationSerialNumber];
    CFTypeRef original = copyItem(-2, asn, key);
    if (!original) return 4;
    printf("before=%s\n", [[(__bridge id)original description] UTF8String]);
    OSStatus status = setItem(-2, asn, key, ui, NULL);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    CFTypeRef after = copyItem(-2, asn, key);
    printf("set UIElement status=%d readback=%s\n", (int)status,
           after ? [[(__bridge id)after description] UTF8String] : "NULL");
    BOOL changed = after && CFEqual(after, ui);
    if (after) CFRelease(after);
    // Always attempt restoration, even if the setter reported an error.
    OSStatus restore = setItem(-2, asn, key, original, NULL);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    CFTypeRef restored = copyItem(-2, asn, key);
    printf("restore status=%d readback=%s\n", (int)restore,
           restored ? [[(__bridge id)restored description] UTF8String] : "NULL");
    BOOL restoredOK = restored && CFEqual(restored, original);
    if (restored) CFRelease(restored);
    CFRelease(original);
    return status == 0 && changed && restore == 0 && restoredOK ? 0 : 5;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        if (argc == 3 && strcmp(argv[1], "--probe") == 0) return probe(atoi(argv[2]));
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,320,160)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        window.title = @"CmdTabo disposable probe";
        [app finishLaunching];
        [window orderBack:nil];
        [window miniaturize:nil];
        printf("test app pid=%d policy=%ld minimized=%d\n", getpid(),
               (long)app.activationPolicy, window.miniaturized);
        if (argc == 2 && strcmp(argv[1], "--self-check") == 0) {
            [NSTimer scheduledTimerWithTimeInterval:2 repeats:NO block:^(NSTimer *timer) {
                SetItem setItem = (SetItem)dlsym(RTLD_DEFAULT, "_LSSetApplicationInformationItem");
                CopyItem copyItem = (CopyItem)dlsym(RTLD_DEFAULT, "_LSCopyApplicationInformationItem");
                CFStringRef key = symbolString("_kLSApplicationTypeKey");
                CFStringRef ui = symbolString("_kLSApplicationUIElementTypeKey");
                CFTypeRef asn = [[NSRunningApplication currentApplication] applicationSerialNumber];
                if (!setItem || !copyItem || !key || !ui || !asn) {
                    fprintf(stderr, "self-check missing runtime dependency\n");
                    [app terminate:nil];
                    return;
                }
                BOOL baselineAccessory = [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
                CFTypeRef baseline = copyItem(-2, asn, key);
                printf("baseline AppKit accessory success=%d type=%s\n", baselineAccessory,
                       baseline ? [[(__bridge id)baseline description] UTF8String] : "NULL");
                if (baseline) CFRelease(baseline);
                BOOL baselineRegular = [app setActivationPolicy:NSApplicationActivationPolicyRegular];
                baseline = copyItem(-2, asn, key);
                printf("baseline AppKit regular success=%d type=%s\n", baselineRegular,
                       baseline ? [[(__bridge id)baseline description] UTF8String] : "NULL");
                if (baseline) CFRelease(baseline);
                OSStatus status = setItem(-2, asn, key, ui, NULL);
                CFTypeRef value = copyItem(-2, asn, key);
                printf("self private setter status=%d type=%s minimized=%d\n", (int)status,
                       value ? [[(__bridge id)value description] UTF8String] : "NULL", window.miniaturized);
                if (value) CFRelease(value);
                BOOL changed = [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
                value = copyItem(-2, asn, key);
                printf("self AppKit accessory success=%d type=%s\n", changed,
                       value ? [[(__bridge id)value description] UTF8String] : "NULL");
                if (value) CFRelease(value);
                BOOL restored = [app setActivationPolicy:NSApplicationActivationPolicyRegular];
                value = copyItem(-2, asn, key);
                printf("self AppKit regular success=%d type=%s\n", restored,
                       value ? [[(__bridge id)value description] UTF8String] : "NULL");
                if (value) CFRelease(value);
                [app terminate:nil];
            }];
        }
        [NSTimer scheduledTimerWithTimeInterval:12 repeats:NO block:^(NSTimer *timer) {
            printf("test app exiting policy=%ld minimized=%d\n", (long)app.activationPolicy, window.miniaturized);
            [app terminate:nil];
        }];
        [app run];
    }
    return 0;
}
