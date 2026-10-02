#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static BOOL (*hostSetPolicy)(id, SEL, NSApplicationActivationPolicy);
static NSApplicationActivationPolicy requestedPolicy;
static BOOL started, suppressed, reconcileQueued, applyingPolicy;
static NSMutableArray *observers;
static NSTimer *reconcileTimer;

BOOL CmdTaboIsLoaded(void) { return started; }

static void trace(NSString *message) {
    if (getenv("CMDTABO_DEBUG")) fprintf(stderr, "[CmdTabo] %s\n", message.UTF8String);
}

// Minimized document windows count; utility panels and attached sheets do not.
static BOOL allDocumentWindowsMinimized(void) {
    NSUInteger count = 0;
    for (NSWindow *window in NSApp.windows) {
        if ([window isKindOfClass:NSPanel.class] || window.sheetParent || window.parentWindow ||
            (!window.canBecomeMainWindow && !window.miniaturized) ||
            (!window.visible && !window.miniaturized)) continue;
        count++;
        if (!window.miniaturized) return NO;
    }
    return count > 0;
}

static void reconcile(void) {
    if (!started || applyingPolicy || requestedPolicy != NSApplicationActivationPolicyRegular) return;
    BOOL nextSuppressed = allDocumentWindowsMinimized();
    NSApplicationActivationPolicy desired = nextSuppressed
        ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular;
    if (NSApp.activationPolicy == desired) {
        suppressed = nextSuppressed;
        return;
    }
    applyingPolicy = YES;
    BOOL wasActive = NSApp.active;
    BOOL success = hostSetPolicy(NSApp, @selector(setActivationPolicy:), desired);
    applyingPolicy = NO;
    if (success) {
        suppressed = nextSuppressed;
        trace([NSString stringWithFormat:@"policy=%ld minimizedOnly=%d", (long)desired, suppressed]);
        if (!suppressed && wasActive) [NSApp activateIgnoringOtherApps:YES];
    } else {
        trace([NSString stringWithFormat:@"policy change rejected: %ld", (long)desired]);
    }
}

static void queueReconcile(void) {
    if (reconcileQueued || !started) return;
    reconcileQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        reconcileQueued = NO;
        reconcile();
    });
}

static BOOL interceptedPolicy(id app, SEL selector, NSApplicationActivationPolicy policy) {
    if (!NSThread.isMainThread || !started || applyingPolicy) return hostSetPolicy(app, selector, policy);
    NSApplicationActivationPolicy effective = policy;
    BOOL nextSuppressed = policy == NSApplicationActivationPolicyRegular && allDocumentWindowsMinimized();
    if (nextSuppressed) effective = NSApplicationActivationPolicyAccessory;
    BOOL success = hostSetPolicy(app, selector, effective);
    if (success) {
        requestedPolicy = policy;
        suppressed = nextSuppressed;
        queueReconcile();
    }
    return success;
}

static void start(void) {
    if (started) return;
    requestedPolicy = NSApp.activationPolicy;
    // Do not promote apps that were deliberately launched as agents.
    if (requestedPolicy != NSApplicationActivationPolicyRegular) {
        trace(@"not a regular app; leaving activation policy alone");
        return;
    }
    Method method = class_getInstanceMethod(NSApplication.class, @selector(setActivationPolicy:));
    if (!method) return;
    hostSetPolicy = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)interceptedPolicy);
    started = YES;
    observers = [NSMutableArray array];
    NSArray *names = @[NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification,
        NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
        NSWindowDidExposeNotification, NSWindowWillCloseNotification,
        NSApplicationDidHideNotification, NSApplicationDidUnhideNotification,
        NSApplicationDidBecomeActiveNotification];
    for (NSString *name in names) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; queueReconcile(); }];
        [observers addObject:token];
    }
    // Reconcile windows ordered without a notification, including background windows.
    reconcileTimer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) { (void)timer; reconcile(); }];
    [NSRunLoop.mainRunLoop addTimer:reconcileTimer forMode:NSRunLoopCommonModes];
    trace(@"loaded; observing this app's windows");
    queueReconcile();
}

__attribute__((constructor)) static void loadCmdTabo(void) {
    @autoreleasepool {
        trace(@"library constructor");
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; start(); }];
        // Does not instantiate NSApplication before the host initializes it.
        dispatch_async(dispatch_get_main_queue(), ^{ if (NSApp && NSApp.running) start(); });
    }
}
