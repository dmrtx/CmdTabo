#import <AppKit/AppKit.h>
#import <dlfcn.h>

typedef CFTypeRef (*CopyItem)(int, CFTypeRef, CFTypeRef);
@interface NSRunningApplication (TestSPI)
- (CFTypeRef)applicationSerialNumber;
@end

@interface TrialDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *first;
@property NSWindow *second;
@property NSUInteger stage;
@property NSUInteger attempts;
@property NSUInteger failures;
@property NSTimer *timer;
- (void)ping:(id)sender;
@end

@implementation TrialDelegate
- (NSWindow *)newWindow:(NSString *)title {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,420,220)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.title = title;
    [window orderBack:nil];
    return window;
}
- (void)ping:(id)sender { NSLog(@"CmdTabo menu action works"); }
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    printf("trial didFinishLaunching\n");
    self.first = [self newWindow:@"CmdTabo test A"];
    self.second = [self newWindow:@"CmdTabo test B"];
    NSMenu *main = [NSMenu new];
    NSMenuItem *root = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *ping = [[NSMenuItem alloc] initWithTitle:@"Test action" action:@selector(ping:) keyEquivalent:@"p"];
    ping.target = self;
    [appMenu addItem:ping];
    NSMenuItem *minimize = [[NSMenuItem alloc] initWithTitle:@"Minimize test window"
        action:@selector(miniaturize:) keyEquivalent:@"m"];
    minimize.target = self.first;
    [appMenu addItem:minimize];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit CmdTaboTrial"
        action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenu addItem:quit];
    root.submenu = appMenu;
    [main addItem:root];
    NSApp.mainMenu = main;
    if (getenv("CMDTABO_MANUAL")) {
        [self.second close];
        [self.first makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        return;
    }
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(tick:)
        userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:35 repeats:NO block:^(NSTimer *timer) {
        (void)timer; fprintf(stderr, "FAIL watchdog timeout\n"); exit(2);
    }];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visible {
    (void)application; (void)visible;
    if (getenv("CMDTABO_MANUAL")) {
        [self.first deminiaturize:nil];
        [self.first makeKeyAndOrderFront:nil];
    }
    return YES;
}
- (BOOL)checkPolicy:(NSApplicationActivationPolicy)expected label:(NSString *)label {
    CopyItem copy = (CopyItem)dlsym(RTLD_DEFAULT, "_LSCopyApplicationInformationItem");
    CFStringRef *key = dlsym(RTLD_DEFAULT, "_kLSApplicationTypeKey");
    CFTypeRef value = copy && key ? copy(-2,
        [[NSRunningApplication currentApplication] applicationSerialNumber], *key) : NULL;
    NSString *type = value ? [(__bridge id)value description] : @"unavailable";
    BOOL matches = NSApp.activationPolicy == expected &&
        [type isEqualToString:expected == NSApplicationActivationPolicyAccessory ? @"UIElement" : @"Foreground"];
    if (value) CFRelease(value);
    if (!matches && ++self.attempts < 15) return NO;
    printf("%s %s policy=%ld type=%s A=%d/%d B=%d/%d\n", matches ? "PASS" : "FAIL", label.UTF8String,
        (long)NSApp.activationPolicy, type.UTF8String, self.first.visible, self.first.miniaturized,
        self.second.visible, self.second.miniaturized);
    if (!matches) self.failures++;
    self.attempts = 0;
    return YES;
}
- (void)tick:(NSTimer *)timer {
    switch (self.stage) {
        case 0:
            {
                BOOL (*loaded)(void) = dlsym(RTLD_DEFAULT, "CmdTaboIsLoaded");
                if (!loaded || !loaded()) { fprintf(stderr, "FAIL library not active\n"); exit(2); }
            }
            if (![self checkPolicy:0 label:@"two visible windows"]) return;
            [self.first miniaturize:nil]; break;
        case 1:
            if (!self.first.miniaturized) return;
            if (![self checkPolicy:0 label:@"one minimized, one visible"]) return;
            [self.second miniaturize:nil]; break;
        case 2:
            if (![self checkPolicy:1 label:@"all minimized"]) return;
            // Simulates an app trying to promote itself while suppressed.
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; break;
        case 3:
            if (![self checkPolicy:1 label:@"host promotion stays filtered"]) return;
            [self.first deminiaturize:nil]; break;
        case 4:
            if (![self checkPolicy:0 label:@"restore one window"]) return;
            if (!self.first.visible || self.first.miniaturized) self.failures++;
            [self.first miniaturize:nil]; break;
        case 5:
            if (![self checkPolicy:1 label:@"minimize again"]) return;
            [self.second close]; self.second = [self newWindow:@"New visible window"];
            break;
        case 6:
            if (![self checkPolicy:0 label:@"new visible window restores app"]) return;
            [self.first close]; [self.second close]; break;
        case 7:
            if (![self checkPolicy:0 label:@"zero windows stays regular"]) return;
            self.first = [self newWindow:@"Hide test"];
            [NSApp hide:nil]; break;
        case 8:
            if (![self checkPolicy:0 label:@"hidden is not minimized"]) return;
            [NSApp unhideWithoutActivation]; [self.first orderBack:nil]; break;
        case 9:
            if (![self checkPolicy:0 label:@"shown without minimizing"]) return;
            [NSApp.mainMenu.itemArray.firstObject.submenu performActionForItemAtIndex:0];
            [timer invalidate];
            printf("RESULT failures=%lu\n", (unsigned long)self.failures);
            exit(self.failures ? 1 : 0);
    }
    self.stage++;
}
@end

int main(void) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        printf("trial main pid=%d\n", getpid());
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        TrialDelegate *delegate = [TrialDelegate new];
        app.delegate = delegate;
        [app finishLaunching];
        [app run];
    }
    return 0;
}
