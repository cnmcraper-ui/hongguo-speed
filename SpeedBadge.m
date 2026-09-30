#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>

// 红果短剧 com.phoenix.video（包内 Eggplant.app，7.3.9.32，cryptid=0）。
// 脱壳主程序 ObjC 符号表确认：播放器是字节自研 TTVideoEngine，倍速接口
//   -setPlaySpeed: / -setPlaySpeedWithRate: / -playSpeed(Td) / -setDefaultPlaySpeed:(T@"NSString")
// 另有大量 BDAO*Speed* 的倍速 UI 类。AVPlayer 只作兜底（广告、听书）。

static const float kRates[] = { 1.0f, 1.25f, 1.5f, 2.0f };
static const int kRateCount = 4;
static int gRateIndex = 0;

enum { kKindDouble, kKindFloat, kKindIntPercent };

typedef struct {
    Class cls;
    SEL setter;
    IMP orig;
    int kind;
    BOOL primary;
} HGEntry;

static HGEntry gEntries[8];
static int gEntryCount = 0;
static NSHashTable *gPlayers = nil;
static UIView *gBadge = nil;
static UILabel *gReport = nil;
static NSArray<NSString *> *gScanResult = nil;
static IMP gOrigAVPlay = NULL;

static float CurRate(void) { return kRates[gRateIndex]; }
static BOOL Forcing(void) { return gRateIndex != 0; }

static HGEntry *Match(id obj, SEL sel, BOOL requirePrimary) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        for (int i = 0; i < gEntryCount; i++) {
            if (gEntries[i].cls != c) continue;
            if (requirePrimary ? !gEntries[i].primary : gEntries[i].setter != sel) continue;
            return &gEntries[i];
        }
    }
    return NULL;
}

static void Write(HGEntry *entry, id target, float rate) {
    SEL sel = entry->setter;
    switch (entry->kind) {
        case kKindFloat:
            ((void (*)(id, SEL, float))entry->orig)(target, sel, rate);
            break;
        case kKindIntPercent:
            ((void (*)(id, SEL, int))entry->orig)(target, sel, (int)lroundf(rate * 100.0f));
            break;
        default:
            ((void (*)(id, SEL, double))entry->orig)(target, sel, (double)rate);
            break;
    }
}

static void ApplyToTracked(float rate) {
    for (id target in gPlayers.allObjects) {
        HGEntry *entry = Match(target, NULL, YES);
        if (entry) Write(entry, target, rate);
    }
}

static void EnsureBadge(void);

// 应用把速度写回 1.0（起播、切集、重置）时替换成按钮当前倍率
static void HK_set_double(id self, SEL _cmd, double value) {
    [gPlayers addObject:self];
    HGEntry *entry = Match(self, _cmd, NO);
    if (!entry) return;
    if (Forcing() && fabs(value - 1.0) < 0.001) value = CurRate();
    Write(entry, self, (float)value);
}

static void HK_set_float(id self, SEL _cmd, float value) {
    [gPlayers addObject:self];
    HGEntry *entry = Match(self, _cmd, NO);
    if (!entry) return;
    if (Forcing() && fabsf(value - 1.0f) < 0.001f) value = CurRate();
    Write(entry, self, value);
}

static void HK_set_intpercent(id self, SEL _cmd, int value) {
    [gPlayers addObject:self];
    HGEntry *entry = Match(self, _cmd, NO);
    if (!entry) return;
    if (Forcing() && value == 100) value = (int)lroundf(CurRate() * 100.0f);
    Write(entry, self, (float)value);
}

static int KindForEncoding(const char *encoding) {
    if (!encoding) return kKindDouble;
    for (const char *p = encoding; *p; p++) {
        if (*p == 'd') return kKindDouble;
        if (*p == 'f') return kKindFloat;
        if (*p == 'i' || *p == 'q') return kKindIntPercent;
    }
    return kKindDouble;
}

static BOOL InstallForClass(const char *className, const char *setterName, BOOL primary) {
    Class cls = objc_getClass(className);
    if (!cls || gEntryCount == 8) return NO;

    SEL setter = sel_registerName(setterName);
    Method own = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == setter) { own = methods[i]; break; }
    }
    free(methods);
    if (!own) return NO;

    int kind = KindForEncoding(method_getTypeEncoding(own));
    IMP wrapper = kind == kKindFloat ? (IMP)HK_set_float
                : kind == kKindIntPercent ? (IMP)HK_set_intpercent
                                          : (IMP)HK_set_double;
    IMP orig = method_setImplementation(own, wrapper);

    gEntries[gEntryCount].cls = cls;
    gEntries[gEntryCount].setter = setter;
    gEntries[gEntryCount].orig = orig;
    gEntries[gEntryCount].kind = kind;
    gEntries[gEntryCount].primary = primary;
    gEntryCount++;
    return YES;
}

// 兜底：系统播放器 AVPlayer 走 play + setRate:
static void HK_avplay(id self, SEL _cmd) {
    [gPlayers addObject:self];
    if (gOrigAVPlay) ((void (*)(id, SEL))gOrigAVPlay)(self, _cmd);
    if (!Forcing()) return;

    Method rate = class_getInstanceMethod(object_getClass(self), @selector(setRate:));
    if (!rate) return;
    const char *enc = method_getTypeEncoding(rate);
    IMP impl = method_getImplementation(rate);
    if (enc && strchr(enc, 'd')) ((void (*)(id, SEL, double))impl)(self, @selector(setRate:), CurRate());
    else ((void (*)(id, SEL, float))impl)(self, @selector(setRate:), CurRate());
}

static NSArray<NSString *> *ScanOnce(void) {
    if (gScanResult) return gScanResult;

    static const char *kWatched[] = {
        "defaultPlaySpeed", "setDefaultPlaySpeed:", "setPlaySpeed:", "playSpeed",
        "setPlaySpeedWithRate:", "updatePlaySpeed:", "playSpeedBtnAction", "mPlaySpeedArray"
    };
    NSMutableArray *lines = [NSMutableArray array];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count && lines.count < 20; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if (![name containsString:@"Engine"] && ![name containsString:@"Player"] && ![name containsString:@"Speed"]) continue;
        for (int k = 0; k < 8; k++) {
            SEL sel = sel_registerName(kWatched[k]);
            if (class_getInstanceMethod(cls, sel)) {
                [lines addObject:[NSString stringWithFormat:@"%@ %@", name, NSStringFromSelector(sel)]];
                break;
            }
        }
    }
    free(classes);
    gScanResult = lines;
    return lines;
}

@interface HGSpeedBadge : UIView {
    UILabel *_label;
    CGPoint _startPoint;
    BOOL _dragged;
    NSUInteger _scanPage;
}
- (void)refresh;
- (void)showScan:(UILongPressGestureRecognizer *)gesture;
@end

@implementation HGSpeedBadge

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.30];
        self.layer.cornerRadius = frame.size.width * 0.5;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.30].CGColor;
        self.alpha = 0.45;

        _label = [[UILabel alloc] initWithFrame:frame];
        _label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _label.textAlignment = NSTextAlignmentCenter;
        _label.textColor = [UIColor whiteColor];
        _label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        [self addSubview:_label];

        UILongPressGestureRecognizer *longPress =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(showScan:)];
        longPress.minimumPressDuration = 0.6;
        [self addGestureRecognizer:longPress];

        [self refresh];
    }
    return self;
}

- (void)refresh {
    _label.text = [NSString stringWithFormat:@"%.3g", CurRate()];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _dragged = NO;
    _startPoint = [[touches anyObject] locationInView:self.superview];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UIView *container = self.superview;
    if (!container) return;
    CGPoint point = [[touches anyObject] locationInView:container];
    if (!_dragged && hypot(point.x - _startPoint.x, point.y - _startPoint.y) < 10.0) return;
    _dragged = YES;

    CGFloat edge = self.frame.size.width * 0.5 + 8.0;
    CGFloat x = fmin(fmax(point.x, edge), container.bounds.size.width - edge);
    CGFloat y = fmin(fmax(point.y, edge), container.bounds.size.height - edge - 40.0);
    self.center = CGPointMake(x, y);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_dragged) return;
    gRateIndex = (gRateIndex + 1) % kRateCount;
    [self refresh];
    ApplyToTracked(CurRate());
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _dragged = NO;
}

// 长按：显示真机上实际发现的倍速接口和已挂点，截图即可定下一步
- (void)showScan:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    NSArray<NSString *> *found = ScanOnce();
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"hook %d | 实例 %lu", gEntryCount,
                                                   (unsigned long)gPlayers.allObjects.count]];
    for (int i = 0; i < gEntryCount; i++) {
        [lines addObject:[NSString stringWithFormat:@"已挂 %@", NSStringFromClass(gEntries[i].cls)]];
    }
    NSUInteger start = _scanPage % (found.count + 1);
    for (NSUInteger i = start; i < found.count && lines.count < 12; i++) {
        [lines addObject:found[i]];
    }
    _scanPage++;

    if (!gReport) {
        gReport = [[UILabel alloc] initWithFrame:CGRectMake(12, 70, 290, 220)];
        gReport.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        gReport.textColor = [UIColor whiteColor];
        gReport.font = [UIFont systemFontOfSize:10.0];
        gReport.numberOfLines = 0;
        gReport.layer.cornerRadius = 8.0;
    }
    gReport.text = [lines componentsJoinedByString:@"\n"];
    UIView *container = self.window ? : UIApplication.sharedApplication.keyWindow;
    if (container) {
        [container addSubview:gReport];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [gReport removeFromSuperview];
        });
    }
}

@end

static void EnsureBadge(void) {
    if (gBadge && gBadge.window) return;
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) window = UIApplication.sharedApplication.windows.firstObject;
    if (!window) return;

    if (!gBadge) gBadge = [[HGSpeedBadge alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    CGSize size = window.bounds.size;
    gBadge.center = CGPointMake(size.width - 34.0, floor(size.height * 0.40));
    [window addSubview:gBadge];
}

static void InstallHooks(void) {
    InstallForClass("TTVideoEngine", "setPlaySpeed:", YES);
    InstallForClass("TTVideoEngine", "setPlaySpeedWithRate:", NO);
    InstallForClass("BDAOVideoEngine", "setPlaySpeed:", NO);

    Class avPlayer = objc_getClass("AVPlayer");
    if (avPlayer) {
        Method play = class_getInstanceMethod(avPlayer, @selector(play));
        if (play) gOrigAVPlay = method_setImplementation(play, (IMP)HK_avplay);
    }
}

__attribute__((constructor)) static void HGSpeedInit(void) {
    gPlayers = [NSHashTable weakObjectsHashTable];
    InstallHooks();

    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(NULL,
        CFAbsoluteTimeGetCurrent() + 1.0, 0.5, 0, 0, ^(CFRunLoopTimerRef t) { EnsureBadge(); });
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
}
