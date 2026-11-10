name: build
on: [push, workflow_dispatch]
jobs:
  ipa:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: scaffold
        run: |
          mkdir -p Sources
          cat > project.yml <<'EOF'
          name: probe
          options: { bundleIdPrefix: com.buurza, deploymentTarget: { iOS: "18.0" } }
          targets:
            probe:
              type: application
              platform: iOS
              sources: [Sources]
              entitlements: { path: probe.entitlements }
              info:
                path: Sources/Info.plist
                properties:
                  CFBundleDisplayName: buurd
                  CFBundleShortVersionString: "1.0"
                  CFBundleVersion: "1"
                  UILaunchScreen: {}
              settings:
                ARCHS: "arm64e arm64"
                SUPPORTED_PLATFORMS: "iphoneos"
                SDKROOT: "iphoneos"
                CODE_SIGN_IDENTITY: ""
                CODE_SIGNING_REQUIRED: "NO"
                CODE_SIGNING_ALLOWED: "NO"
              dependencies:
                - sdk: IOKit.framework
                - sdk: UIKit.framework
          EOF
          cat > probe.entitlements <<'EOF'
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
            <key>platform-application</key><true/>
            <key>com.apple.private.security.no-container</key><true/>
          </dict></plist>
          EOF
          cat > Sources/main.m <<'EOF'
          #import <UIKit/UIKit.h>
          #import <IOKit/IOKitLib.h>

          static UILabel* g_label;

          static void set_text(NSString* s) {
              dispatch_async(dispatch_get_main_queue(), ^{
                  g_label.text = s;
                  NSLog(@"PROBE: %@", s);
              });
          }

          static void run_probe(void) {
              io_iterator_t it = 0;
              if (IOServiceGetMatchingServices(kIOMainPortDefault,
                      IOServiceMatching("AVEVideoEncoder"), &it) != KERN_SUCCESS) {
                  set_text(@"NO SERVICE"); return;
              }
              io_service_t svc = IOIteratorNext(it);
              IOObjectRelease(it);
              if (!svc) { set_text(@"NO INSTANCE"); return; }
              io_connect_t c = 0;
              kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c);
              if (kr == KERN_SUCCESS) {
                  set_text([NSString stringWithFormat:@"REACHABLE\nkr=0x%x\nconn=%u", kr, c]);
              } else {
                  set_text([NSString stringWithFormat:@"BLOCKED\nkr=0x%x", kr]);
              }
          }

          @interface AppDelegate : UIResponder <UIApplicationDelegate>
          @property (strong) UIWindow* w;
          @end

          @implementation AppDelegate
          - (BOOL)application:(UIApplication*)a didFinishLaunchingWithOptions:(NSDictionary*)o {
              self.w = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
              UIViewController* vc = [UIViewController new];
              vc.view.backgroundColor = UIColor.blackColor;

              g_label = [[UILabel alloc] initWithFrame:vc.view.bounds];
              g_label.numberOfLines = 0;
              g_label.textAlignment = NSTextAlignmentCenter;
              g_label.textColor = UIColor.greenColor;
              g_label.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightBold];
              g_label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
              g_label.text = @"running...";
              [vc.view addSubview:g_label];

              self.w.rootViewController = vc;
              [self.w makeKeyAndVisible];
              dispatch_async(dispatch_get_global_queue(0,0), ^{ run_probe(); });
              return YES;
          }
          @end

          int main(int argc, char** argv) {
              @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); }
          }
          EOF

      - name: xcodegen
        run: |
          brew install xcodegen
          xcodegen generate

      - name: build
        run: |
          mkdir -p out/Payload
          xcodebuild -project probe.xcodeproj -target probe \
            -sdk iphoneos -configuration Release \
            -arch arm64e -arch arm64 \
            CONFIGURATION_BUILD_DIR=$PWD/out/Payload \
            SUPPORTED_PLATFORMS=iphoneos \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
            build

      - name: ipa
        run: |
          ls -la out/Payload
          cd out && zip -r probe.ipa Payload

      - uses: actions/upload-artifact@v4
        with:
          name: probe
          path: out/probe.ipa
          if-no-files-found: error
