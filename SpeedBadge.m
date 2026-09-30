#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>

// 红果短剧 com.phoenix.video。
// v2 真机长按面板实测：TTVideoEngine 在运行时并不响应 setPlaySpeed:（脱壳符号表里的类归属看错了），
// 真正带倍速 setter 的是 SSPlayer(updatePlaySpeed:)、BDSCPlayer / BDSCAirPlayPlayer / BDLinkPlayer /
// BDLEPlayer / BDDInaPlayer / BDByteCastPlayer / BDAirDisplayPlayer / TTVideoEngineEventBase(setPlaySpeed:)。
// 所以本版不写死类名：运行时扫描"名字像播放器的类 + 其继承链"，在真正声明该 setter 的那个类上换 IMP。

static const float kRates[] = { 1.0f, 1.25f, 1.5f, 2.0f };
static const int kRateCount = 4;
static int gRateIndex = 0;

enum { kKindDouble, kKindFloat, kKindIntPercent, kKindTrack };

typedef struct {
    Class cls;
    SEL setter;
    IMP orig;
    int kind;
} HGEntry;

#define kMaxEntries 32
static HGEntry gEntries[kMaxEntries];
static int gEntryCount = 0;
static int gSkipped = 0;
static BOOL gDiscovered = NO;
static NSHashTable *gPlayers = nil;
static UIView *gBadge = nil;
static UILabel *gReport = nil;
static NSString *gLastWrite = nil;
static NSArray<NSString *> *gScanResult = nil;

static UIWindow *KeyWindow(void);
static void EnsureBadge(void);

static float CurRate(void) { return kRates[gRateIndex]; }
static BOOL Forcing(void) { return gRateIndex != 0; }

static void Track(id obj) {
    @synchronized (gPlayers) { [gPlayers addObject:obj]; }
}

static void Note(id obj, SEL sel, double value) {
    NSString *line = [NSString stringWithFormat:@"%@ %@=%.3g",
                                  NSStringFromClass(object_getClass(obj)),
                                  NSStringFromSelector(sel), value];
    @synchronized (gPlayers) { gLastWrite = line; }
}

static HGEntry *Match(id obj, SEL sel) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        for (int i = 0; i < gEntryCount; i++) {
            if (gEntries[i].cls == c && gEntries[i].setter == sel) return &gEntries[i];
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

// 只有"现在真的在播"的对象才推倍率，避免点到按钮把后台停着的播放器（广告、听书）拽起来
static BOOL LikelyPlaying(id target) {
    SEL rateSel = sel_registerName("rate");
    Method m = class_getInstanceMethod(object_getClass(target), rateSel);
    if (!m || method_getNumberOfArguments(m) != 2) return YES;
    char *type = method_copyReturnType(m);
    BOOL scalar = type && (type[0] == 'd' || type[0] == 'f');
    free(type);
    if (!scalar) return YES;
    double rate = ((double (*)(id, SEL))method_getImplementation(m))(target, rateSel);
    return rate != 0.0;
}

static void ApplyAll(float rate) {
    NSArray *targets;
    @synchronized (gPlayers) { targets = gPlayers.allObjects; }
    for (id target in targets) {
        if (!LikelyPlaying(target)) continue;
        for (Class c = object_getClass(target); c; c = class_getSuperclass(c)) {
            for (int i = 0; i < gEntryCount; i++) {
                if (gEntries[i].cls != c || gEntries[i].kind == kKindTrack) continue;
                Write(&gEntries[i], target, rate);
            }
        }
    }
}

static void HK_set_double(id self, SEL _cmd, double value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    if (Forcing() && fabs(value - 1.0) < 0.001) value = CurRate();
    Note(self, _cmd, value);
    Write(entry, self, (float)value);
}

static void HK_set_float(id self, SEL _cmd, float value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    if (Forcing() && fabsf(value - 1.0f) < 0.001f) value = CurRate();
    Note(self, _cmd, value);
    Write(entry, self, value);
}

static void HK_set_intpercent(id self, SEL _cmd, int value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    float rate = value / 100.0f;
    if (Forcing() && value == 100) rate = CurRate();
    Note(self, _cmd, rate);
    Write(entry, self, rate);
}

// 生命周期钩子只负责"认出这个播放器实例"，不改动任何行为
static void HK_track(id self, SEL _cmd) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (entry && entry->orig) ((void (*)(id, SEL))entry->orig)(self, _cmd);
}

static IMP WrapperFor(int kind) {
    switch (kind) {
        case kKindFloat: return (IMP)HK_set_float;
        case kKindIntPercent: return (IMP)HK_set_intpercent;
        case kKindTrack: return (IMP)HK_track;
        default: return (IMP)HK_set_double;
    }
}

static void InstallEntry(Class cls, SEL sel, Method method, int kind) {
    if (gEntryCount == kMaxEntries) return;
    for (int i = 0; i < gEntryCount; i++) {
        if (gEntries[i].cls == cls && gEntries[i].setter == sel) return;
    }
    gEntries[gEntryCount].cls = cls;
    gEntries[gEntryCount].setter = sel;
    gEntries[gEntryCount].orig = method_setImplementation(method, WrapperFor(kind));
    gEntries[gEntryCount].kind = kind;
    gEntryCount++;
}

static const char *kSpeedSetters[] = {
    "setPlaySpeed:", "updatePlaySpeed:", "setPlaySpeedWithRate:", "setRate:", "setSpeed:"
};
static const char *kTrackSetters[] = { "play", "start", "playOrResume", "resumePlay" };
static SEL gSpeedSels[5];
static SEL gTrackSels[4];

// 参数必须是标量才敢按倍率写；对象/结构体参数一律跳过（计入"跳过 K"）
static int ScalarKind(Method method) {
    if (method_getNumberOfArguments(method) != 3) return -1;
    char *type = method_copyArgumentType(method, 2);
    if (!type) return -1;
    char head = type[0];
    free(type);
    if (head == 'd') return kKindDouble;
    if (head == 'f') return kKindFloat;
    if (head == 'i' || head == 'q') return kKindIntPercent;
    return -1;
}

static BOOL Playerish(NSString *name) {
    return [name containsString:@"Player"] || [name containsString:@"Engine"] ||
           [name containsString:@"Speed"];
}

static void Discover(void) {
    if (gDiscovered) return;
    gDiscovered = YES;

    for (int k = 0; k < 5; k++) gSpeedSels[k] = sel_registerName(kSpeedSetters[k]);
    for (int k = 0; k < 4; k++) gTrackSels[k] = sel_registerName(kTrackSetters[k]);

    // 同一个祖先类（NSObject 等）只扫一次；链上遇到扫过的类就直接停
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        if (!Playerish(NSStringFromClass(classes[i]))) continue;

        for (Class c = classes[i]; c; c = class_getSuperclass(c)) {
            NSString *owner = NSStringFromClass(c);
            if ([visited containsObject:owner]) break;
            [visited addObject:owner];

            unsigned int n = 0;
            Method *methods = class_copyMethodList(c, &n);
            for (unsigned int j = 0; j < n; j++) {
                SEL sel = method_getName(methods[j]);
                BOOL handled = NO;
                for (int k = 0; k < 5 && !handled; k++) {
                    if (sel != gSpeedSels[k]) continue;
                    handled = YES;
                    int kind = ScalarKind(methods[j]);
                    if (kind >= 0) InstallEntry(c, sel, methods[j], kind);
                    else gSkipped++;
                }
                for (int k = 0; k < 4 && !handled; k++) {
                    if (sel != gTrackSels[k]) continue;
                    handled = YES;
                    if (method_getNumberOfArguments(methods[j]) == 2) {
                        InstallEntry(c, sel, methods[j], kKindTrack);
                    }
                }
            }
            free(methods);
        }
    }
    free(classes);
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
    for (unsigned int i = 0; i < count && lines.count < 24; i++) {
        Class cls = classes[i];
        if (!Playerish(NSStringFromClass(cls))) continue;
        for (int k = 0; k < 8; k++) {
            SEL sel = sel_registerName(kWatched[k]);
            if (class_getInstanceMethod(cls, sel)) {
                [lines addObject:[NSString stringWithFormat:@"%@ %@",
                                            NSStringFromClass(cls), NSStringFromSelector(sel)]];
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
    Discover();
    gRateIndex = (gRateIndex + 1) % kRateCount;
    [self refresh];
    ApplyAll(CurRate());
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _dragged = NO;
}

// 长按：显示真机上实际挂到了什么，截图即可定下一步
- (void)showScan:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    Discover();
    NSArray<NSString *> *found = ScanOnce();
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"hook %d | 实例 %lu | 跳过 %d",
                                   gEntryCount, (unsigned long)gPlayers.allObjects.count, gSkipped]];
    NSString *last;
    @synchronized (gPlayers) { last = gLastWrite; }
    [lines addObject:last ?: @"还没拦到任何写入"];

    for (int i = 0; i < gEntryCount && lines.count < 8; i++) {
        if (gEntries[i].kind == kKindTrack) continue;
        [lines addObject:[NSString stringWithFormat:@"已挂 %@ %@",
                                      NSStringFromClass(gEntries[i].cls),
                                      NSStringFromSelector(gEntries[i].setter)]];
    }
    NSUInteger start = _scanPage % (found.count + 1);
    for (NSUInteger i = start; i < found.count && lines.count < 14; i++) {
        [lines addObject:found[i]];
    }
    _scanPage++;

    if (!gReport) {
        gReport = [[UILabel alloc] initWithFrame:CGRectMake(12, 70, 300, 260)];
        gReport.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        gReport.textColor = [UIColor whiteColor];
        gReport.font = [UIFont systemFontOfSize:10.0];
        gReport.numberOfLines = 0;
        gReport.layer.cornerRadius = 8.0;
    }
    gReport.text = [lines componentsJoinedByString:@"\n"];
    UIView *container = self.window ?: KeyWindow();
    if (container) {
        [container addSubview:gReport];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [gReport removeFromSuperview];
        });
    }
}

@end

static UIWindow *KeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return UIApplication.sharedApplication.delegate.window;
}

static void EnsureBadge(void) {
    if (gBadge && gBadge.window) return;
    UIWindow *window = KeyWindow();
    if (!window) return;

    if (!gBadge) gBadge = [[HGSpeedBadge alloc] initWithFrame:CGRectMake(0, 0, 48, 48)];
    CGSize size = window.bounds.size;
    gBadge.center = CGPointMake(size.width - 34.0, floor(size.height * 0.40));
    [window addSubview:gBadge];
    Discover();
}

__attribute__((constructor)) static void HGSpeedInit(void) {
    gPlayers = [NSHashTable weakObjectsHashTable];

    // 挂点延迟到浮钮第一次出现时才装（那时 App 的播放器类已经全部加载完）
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(NULL,
        CFAbsoluteTimeGetCurrent() + 1.0, 0.5, 0, 0, ^(CFRunLoopTimerRef t) { EnsureBadge(); });
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
}
