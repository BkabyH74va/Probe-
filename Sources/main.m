#import <UIKit/UIKit.h>
#import <IOKit/IOKitLib.h>
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>

static UITextView* g_tv;
static UILabel* g_hb;
static volatile int g_hits = 0, g_done = 0;
static int g_fd = -1;
static NSMutableSet* g_seen;
static pthread_mutex_t g_lk = PTHREAD_MUTEX_INITIALIZER;

#define MAXC 24
static io_connect_t g_conn[MAXC];
static uint32_t g_ctype[MAXC];
static int g_nconn = 0;

static void ui(NSString* s) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_tv.text = [g_tv.text stringByAppendingFormat:@"\n%@", s];
        [g_tv scrollRangeToVisible:NSMakeRange(g_tv.text.length, 0)];
    });
}
static void persist(NSString* s) {
    if (g_fd < 0) return;
    NSData* d = [[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    pthread_mutex_lock(&g_lk);
    write(g_fd, d.bytes, d.length);
    pthread_mutex_unlock(&g_lk);
}
static NSString* kr_name(kern_return_t kr) {
    switch (kr) {
        case KERN_SUCCESS: return @"OK";
        case 0xe00002bc: return @"Error";
        case 0xe00002bd: return @"NoMem";
        case 0xe00002be: return @"NoRes";
        case 0xe00002c1: return @"NotPriv";
        case 0xe00002c2: return @"BadArg";
        case 0xe00002c5: return @"Excl";
        case 0xe00002c7: return @"Unsup";
        case 0xe00002cc: return @"NotOpen";
        case 0xe00002d4: return @"Busy";
        case 0xe00002e2: return @"NotPerm";
        default: return [NSString stringWithFormat:@"0x%x", kr];
    }
}
static NSString* hex(const uint8_t* p, size_t n) {
    if (!n) return @"-";
    if (n > 512) n = 512;
    NSMutableString* s = [NSMutableString string];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}
static void state_path(char* b, size_t n) {
    NSString* p = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"state.txt"];
    strncpy(b, p.UTF8String, n - 1);
}
static void load_state(void) {
    char b[512]; state_path(b, sizeof(b));
    NSString* s = [NSString stringWithContentsOfFile:@(b) encoding:NSUTF8StringEncoding error:nil];
    for (NSString* ln in [s componentsSeparatedByString:@"\n"]) {
        if (ln.length < 5) continue;
        NSArray* f = [ln componentsSeparatedByString:@" "];
        if (f.count >= 3) [g_seen addObject:[NSString stringWithFormat:@"%@:%@:%@", f[0], f[1], f[2]]];
    }
}
static BOOL seen_key(NSString* k) {
    pthread_mutex_lock(&g_lk);
    BOOL r = [g_seen containsObject:k];
    [g_seen addObject:k];
    pthread_mutex_unlock(&g_lk);
    return r;
}

static kern_return_t callp(const char* tag, io_connect_t c, uint32_t t, uint32_t sel,
                           const uint8_t* in, size_t sz, size_t outsz, BOOL always) {
    NSString* key = [NSString stringWithFormat:@"%u:%u:%zu:%zu:%s", t, sel, sz, outsz, tag];
    if (seen_key(key)) return (kern_return_t)0xdeadbeef;
    uint8_t out[4096]; size_t oSz = outsz;
    memset(out, 0xCC, sizeof(out));
    kern_return_t kr = IOConnectCallStructMethod(c, sel, in, sz, outsz ? out : NULL, &oSz);
    __sync_fetch_and_add(&g_done, 1);
    if (kr == KERN_SUCCESS) {
        persist([NSString stringWithFormat:@"OK %s t%u s%u out=%zu %@ IN %@",
                 tag, t, sel, oSz, hex(out, oSz), hex(in, sz)]);
        __sync_fetch_and_add(&g_hits, 1);
        ui([NSString stringWithFormat:@"!!! OK %s t%u s%u out=%zu %@",
            tag, t, sel, oSz, hex(out, oSz)]);
    } else if (kr != 0xe00002c2 && kr != 0xe00002c7) {
        persist([NSString stringWithFormat:@"%u %u %zu %@ %zu %@ | %s",
                 t, sel, sz, kr_name(kr), oSz, hex(out, 24), tag]);
        __sync_fetch_and_add(&g_hits, 1);
        ui([NSString stringWithFormat:@"!! %s t%u s%u -> %@ %@",
            tag, t, sel, kr_name(kr), hex(out, 24)]);
    } else {
        persist([NSString stringWithFormat:@"%u %u %zu %@ %zu - | %s",
                 t, sel, sz, kr_name(kr), oSz, tag]);
        if (always) ui([NSString stringWithFormat:@"%s t%u s%u -> %@",
                        tag, t, sel, kr_name(kr)]);
    }
    usleep(200);
    return kr;
}

static void cmd_hunt(io_connect_t c, uint32_t t, uint32_t sel) {
    int offs[] = { 120, 124, 126, 128 };
    for (int o = 0; o < 4; o++) {
        for (uint32_t v = 0; v <= 255; v++) {
            uint8_t* in = calloc(1, 4096);
            if (offs[o] == 126) { uint16_t h = v; memcpy(in + 126, &h, 2); }
            else memcpy(in + offs[o], &v, 4);
            char tg[40]; snprintf(tg, sizeof(tg), "cmd%u.%u", offs[o], v);
            callp(tg, c, t, sel, in, 4096, 4096, NO);
            free(in);
        }
    }
    ui([NSString stringWithFormat:@"cmd_hunt s%u done", sel]);
}

static void par_hmap(io_connect_t c, uint32_t t, uint32_t sel) {
    dispatch_group_t g = dispatch_group_create();
    int lo = 128, hi = 4095, span = (hi - lo) / g_nconn + 1;
    for (int n = 0; n < g_nconn; n++) {
        dispatch_group_async(g, dispatch_get_global_queue(0,0), ^{
            int a = lo + n * span, b = a + span; if (b > hi + 1) b = hi + 1;
            uint8_t* in = calloc(1, 4096);
            for (int i = a; i < b; i++) {
                in[i] = 0xFF;
                char tg[40]; snprintf(tg, sizeof(tg), "h%u.%d", sel, i);
                callp(tg, g_conn[n], g_ctype[n], sel, in, 4096, 4096, NO);
                in[i] = 0;
            }
            free(in);
        });
    }
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    ui([NSString stringWithFormat:@"par_hmap s%u done", sel]);
}

static void par_imap(io_connect_t c, uint32_t t, uint32_t sel) {
    dispatch_group_t g = dispatch_group_create();
    int lo = 0, hi = 511, span = (hi - lo) / g_nconn + 1;
    for (int n = 0; n < g_nconn; n++) {
        dispatch_group_async(g, dispatch_get_global_queue(0,0), ^{
            int a = lo + n * span, b = a + span; if (b > hi + 1) b = hi + 1;
            uint8_t* in = malloc(4096);
            memset(in, 0xFF, 4096);
            for (int i = a; i < b; i++) {
                in[i] = 0;
                char tg[40]; snprintf(tg, sizeof(tg), "i%u.%d", sel, i);
                callp(tg, g_conn[n], g_ctype[n], sel, in, 4096, 4096, NO);
                in[i] = 0xFF;
            }
            free(in);
        });
    }
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    ui([NSString stringWithFormat:@"par_imap s%u done", sel]);
}

static void mixed(io_connect_t c, uint32_t t, uint32_t sel) {
    for (uint32_t ic = 0; ic <= 6; ic++) {
        uint64_t inS[8] = {0}, outS[16] = {0}; uint32_t oc = 16;
        uint8_t* in = calloc(1, 4096);
        uint8_t out[4096]; size_t oSz = sizeof(out);
        memset(out, 0xCC, sizeof(out));
        kern_return_t kr = IOConnectCallMethod(c, sel, inS, ic, in, 4096,
                                              outS, &oc, out, &oSz);
        free(in);
        char tg[32]; snprintf(tg, sizeof(tg), "m%u.%u", sel, ic);
        persist([NSString stringWithFormat:@"%u %u mixed %@ | %s", t, sel, kr_name(kr), tg]);
        if (kr != 0xe00002c2 && kr != 0xe00002c7) {
            ui([NSString stringWithFormat:@"!! %s -> %@ oc=%u %@", tg, kr_name(kr), oc, hex(out, oSz)]);
        } else {
            ui([NSString stringWithFormat:@"%s -> %@", tg, kr_name(kr)]);
        }
    }
}

static void fuzz(io_connect_t c, uint32_t t, uint32_t sel, int rounds) {
    for (int r = 0; r < rounds; r++) {
        uint8_t* in = calloc(1, 4096);
        uint32_t n = 1 + arc4random_uniform(6);
        for (uint32_t k = 0; k < n; k++) {
            uint32_t off = arc4random_uniform(1024) & ~3u;
            uint32_t v = (uint32_t[]){ 1,8,16,64,256,1024,4096,8192,0x10000,
                                       0x100000,0x7fffffff,0xffffffff }[arc4random_uniform(12)];
            memcpy(in + off, &v, 4);
        }
        char tg[32]; snprintf(tg, sizeof(tg), "f%u.%d", sel, r);
        callp(tg, c, t, sel, in, 4096, 4096, NO);
        free(in);
    }
    ui([NSString stringWithFormat:@"fuzz s%u done", sel]);
}

static void open_all(void) {
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("AppleJPEGDriver"), &it) != KERN_SUCCESS) return;
    io_service_t s; int nodes = 0;
    while ((s = IOIteratorNext(it)) && nodes < 1 && g_nconn < MAXC) {
        nodes++;
        for (int t = 0; t <= 40 && g_nconn < MAXC; t++) {
            io_connect_t c = 0;
            if (IOServiceOpen(s, mach_task_self(), (uint32_t)t, &c) == KERN_SUCCESS) {
                g_conn[g_nconn] = c; g_ctype[g_nconn] = (uint32_t)t; g_nconn++;
            }
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
}

static void memmap_sweep(io_connect_t c, uint32_t t) {
    for (uint32_t mt = 0; mt < 32; mt++) {
        mach_vm_address_t addr = 0;
        mach_vm_size_t size = 0;
        kern_return_t kr = IOConnectMapMemory64(c, mt, mach_task_self(),
                                                &addr, &size, kIOMapAnywhere);
        char tg[32]; snprintf(tg, sizeof(tg), "mm%u", mt);
        persist([NSString stringWithFormat:@"%u map %u %@ %llu %llu | %s",
                 t, mt, kr_name(kr), addr, size, tg]);
        if (kr != KERN_SUCCESS) {
            ui([NSString stringWithFormat:@"%s -> %@", tg, kr_name(kr)]);
            continue;
        }
        __sync_fetch_and_add(&g_hits, 1);
        ui([NSString stringWithFormat:@"!!! %s MAPPED size=%llu @%llx", tg, size, addr]);

        if (size >= 64) {
            uint8_t* p = (uint8_t*)addr;
            size_t dump = size > 64 ? 64 : (size_t)size;
            NSMutableString* hx = [NSMutableString string];
            for (size_t i = 0; i < dump; i++) [hx appendFormat:@"%02x", p[i]];
            ui([NSString stringWithFormat:@"    pre %@", hx]);

            memset(p, 0xFF, size > 4096 ? 4096 : (size_t)size);

            uint8_t* in = calloc(1, 4096);
            callp("post_mm", c, t, 5, in, 4096, 4096, YES);
            callp("post_mm4", c, t, 4, in, 4096, 4096, YES);
            free(in);

            hx = [NSMutableString string];
            for (size_t i = 0; i < dump; i++) [hx appendFormat:@"%02x", p[i]];
            ui([NSString stringWithFormat:@"    post %@", hx]);

            IOConnectUnmapMemory64(c, mt, mach_task_self(), addr);
        } else {
            IOConnectUnmapMemory64(c, mt, mach_task_self(), addr);
        }
    }
    ui(@"memmap_sweep done");
}

static void run(void) {
    char b[512]; state_path(b, sizeof(b));
    g_fd = open(b, O_CREAT | O_WRONLY | O_APPEND, 0644);
    g_seen = [NSMutableSet set];
    load_state();
    ui([NSString stringWithFormat:@"resume=%lu", (unsigned long)g_seen.count]);

    VTCompressionSessionRef v = NULL;
    VTCompressionSessionCreate(NULL, 1920, 1080, kCMVideoCodecType_H264,
        NULL, NULL, NULL, NULL, NULL, &v);
    if (v) VTCompressionSessionPrepareToEncodeFrames(v);
    usleep(200000);

    open_all();
    ui([NSString stringWithFormat:@"conns=%d", g_nconn]);
    if (!g_nconn) return;

    io_connect_t c = g_conn[0]; uint32_t t = g_ctype[0];

    ui(@"[M] memmap sweep");
    memmap_sweep(g_conn[0], g_ctype[0]);
    if (g_nconn > 1) memmap_sweep(g_conn[1], g_ctype[1]);

    ui(@"[A] command id hunt s5");
    cmd_hunt(c, t, 5);
    ui(@"[A2] command id hunt s4");
    cmd_hunt(c, t, 4);

    ui(@"[B] par hmap s5 128-4095");
    par_hmap(c, t, 5);
    ui(@"[B2] par hmap s4 128-4095");
    par_hmap(c, t, 4);

    ui(@"[C] par inverse s5");
    par_imap(c, t, 5);
    ui(@"[C2] par inverse s4");
    par_imap(c, t, 4);

    ui(@"[D] mixed ABI");
    mixed(c, t, 5);
    mixed(c, t, 4);

    ui(@"[E] fuzz");
    fuzz(c, t, 5, 400);
    fuzz(c, t, 4, 400);

    ui([NSString stringWithFormat:@"FINISHED calls=%d hits=%d", g_done, g_hits]);
    close(g_fd); g_fd = -1;
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow* w;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication*)a didFinishLaunchingWithOptions:(NSDictionary*)o {
    self.w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController* vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.blackColor;

    g_hb = [[UILabel alloc] initWithFrame:CGRectMake(8, 50, 340, 18)];
    g_hb.textColor = UIColor.systemYellowColor;
    g_hb.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    g_hb.text = @"idle";
    [vc.view addSubview:g_hb];

    CGRect r = vc.view.bounds;
    r.origin.y = 72; r.size.height -= 80;
    g_tv = [[UITextView alloc] initWithFrame:r];
    g_tv.backgroundColor = UIColor.blackColor;
    g_tv.textColor = UIColor.greenColor;
    g_tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    g_tv.editable = NO;
    g_tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_tv.text = @"boot";
    [vc.view addSubview:g_tv];

    self.w.rootViewController = vc;
    [self.w makeKeyAndVisible];

    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* t) {
        g_hb.text = [NSString stringWithFormat:@"calls=%d hits=%d", g_done, g_hits];
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                   dispatch_get_global_queue(0,0), ^{ run(); });
    return YES;
}
@end

int main(int argc, char** argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); }
}
