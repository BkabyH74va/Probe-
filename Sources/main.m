#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>

static void run_probe(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("AVEVideoEncoder"), &it) != KERN_SUCCESS) {
        NSLog(@"PROBE: NO SERVICE"); return;
    }
    io_service_t svc = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!svc) { NSLog(@"PROBE: NO INSTANCE"); return; }
    io_connect_t c = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c);
    NSLog(@"PROBE: open = 0x%x (%s)", kr,
          kr == KERN_SUCCESS ? "REACHABLE" : "BLOCKED");
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow* w;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication*)a didFinishLaunchingWithOptions:(NSDictionary*)o {
    self.w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.w.rootViewController = [UIViewController new];
    [self.w makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(0,0), ^{ run_probe(); });
    return YES;
}
@end

int main(int argc, char** argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); }
}
