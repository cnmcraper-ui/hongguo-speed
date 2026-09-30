#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>

// 红果短剧 com.phoenix.video。
// v2 实测：写死 TTVideoEngine → hook 0（脱壳符号表里的类归属看错了）。
// v3 实测：按名字扫出 32 个倍速 setter、登记到 2 个播放器实例，但用红果自己的倍速菜单切到 2.0x 时
//          这 32 个挂点一次都没被调用 → 真正的倍速通道不在"我挑的这批 setter"里。
// v4 改成广谱探针：凡名字含 speed 的方法、常见 rate setter、play/start 全部套上记录壳。
//          数字参数的仍参与替换与推送；对象参数与 0 参数的只记调用、不改行为。
//          长按面板直接点名"红果切倍速时到底调了哪个方法"。

static const float kRates[] = { 1.0f, 1.25f, 1.5f, 2.0f };
static const int kRateCount = 4;
static int gRateIndex = 0;

enum { kKindDouble, kKindFloat, kKindIntPercent, kKindObject, kKindLogVoid, kKindTrack };

typedef struct {
    Class cls;
    SEL setter;
    IMP orig;
    int kind;
    int hits;
    int pushes;
} HGEntry;

#define kMaxEntries 96
static HGEntry gEntries[kMaxEntries];
static int gEntryCount = 0;
static int gSkipped = 0;
static BOOL gDiscovered = NO;
static NSHashTable *gPlayers = nil;
static UIView *gBadge = nil;
static UILabel *gReport = nil;
static NSString *gLastWrite = nil;

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

static void HK_set_double(id self, SEL _cmd, double value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    if (Forcing() && fabs(value - 1.0) < 0.001) value = CurRate();
    Note(self, _cmd, value);
    Write(entry, self, (float)value);
}

static void HK_set_float(id self, SEL _cmd, float value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    if (Forcing() && fabsf(value - 1.0f) < 0.001f) value = CurRate();
    Note(self, _cmd, value);
    Write(entry, self, value);
}

static void HK_set_intpercent(id self, SEL _cmd, int value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    float rate = value / 100.0f;
    if (Forcing() && value == 100) rate = CurRate();
    Note(self, _cmd, rate);
    Write(entry, self, rate);
}

// 对象参数：不猜内容，只记"谁调了它、传进来的是什么类的对象"
static void HK_set_object(id self, SEL _cmd, id value) {
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    @synchronized (gPlayers) {
        gLastWrite = [NSString stringWithFormat:@"%@ %@<-%@",
                                  NSStringFromClass(object_getClass(self)),
                                  NSStringFromSelector(_cmd),
                                  value ? NSStringFromClass(object_getClass(value)) : @"nil"];
    }
    ((void (*)(id, SEL, id))entry->orig)(self, _cmd, value);
}

static void HK_logvoid(id self, SEL _cmd) {
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    ((void (*)(id, SEL))entry->orig)(self, _cmd);
}

// play / start 这类：只登记实例，行为原样
static void HK_track(id self, SEL _cmd) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    ((void (*)(id, SEL))entry->orig)(self, _cmd);
}

static IMP WrapperFor(int kind) {
    switch (kind) {
        case kKindFloat: return (IMP)HK_set_float;
        case kKindIntPercent: return (IMP)HK_set_intpercent;
        case kKindObject: return (IMP)HK_set_object;
        case kKindLogVoid: return (IMP)HK_logvoid;
        case kKindTrack: return (IMP)HK_track;
        default: return (IMP)HK_set_double;
    }
}

static BOOL NumericKind(int kind) {
    return kind == kKindDouble || kind == kKindFloat || kind == kKindIntPercent;
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
    gEntries[gEntryCount].hits = 0;
    gEntries[gEntryCount].pushes = 0;
    gEntryCount++;
}

static const char *kRateNames[] = {
    "setRate:", "setPlaybackRate:", "setPlayRate:", "setTimeRate:", "updateRate:", "setRateValue:"
};
static const char *kPlayNames[] = { "play", "start", "playOrResume", "resumePlay" };

static BOOL HasSpeedWord(const char *name) {
    char buf[80];
    int i = 0;
    for (; name[i] && i < 79; i++) {
        char c = name[i];
        buf[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    buf[i] = 0;
    return strstr(buf, "speed") != NULL;
}

static BOOL Interesting(SEL sel) {
    const char *n = sel_getName(sel);
    if (HasSpeedWord(n)) return YES;
    for (int k = 0; k < 6; k++) if (strcmp(n, kRateNames[k]) == 0) return YES;
    for (int k = 0; k < 4; k++) if (strcmp(n, kPlayNames[k]) == 0) return YES;
    return NO;
}

// 只挂返回 void 的：把返回 double 的 getter 换成 void 壳，调用方会读到垃圾值
static BOOL ReturnsVoid(Method method) {
    char *type = method_copyReturnType(method);
    BOOL yes = type && type[0] == 'v';
    free(type);
    return yes;
}

static int KindFor(Method method) {
    if (!ReturnsVoid(method)) return -1;
    unsigned int args = method_getNumberOfArguments(method);
    if (args == 2) {
        const char *n = sel_getName(method_getName(method));
        for (int k = 0; k < 4; k++) if (strcmp(n, kPlayNames[k]) == 0) return kKindTrack;
        return kKindLogVoid;
    }
    if (args != 3) return -1;
    char *type = method_copyArgumentType(method, 2);
    if (!type) return -1;
    char head = type[0];
    free(type);
    if (head == 'd') return kKindDouble;
    if (head == 'f') return kKindFloat;
    if (head == 'i' || head == 'q') return kKindIntPercent;
    if (head == '@' || head == '#') return kKindObject;
    return -1;
}

// 只有 setRate: / setSpeed: 这类"写下去会真的推动播放"的接口，才需要确认它在播
static BOOL RateLikeSetter(SEL sel) {
    return sel == sel_registerName("setRate:") || sel == sel_registerName("setSpeed:");
}

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
        BOOL playing = NO, checked = NO;
        for (Class c = object_getClass(target); c; c = class_getSuperclass(c)) {
            for (int i = 0; i < gEntryCount; i++) {
                if (gEntries[i].cls != c || !NumericKind(gEntries[i].kind)) continue;
                if (RateLikeSetter(gEntries[i].setter)) {
                    if (!checked) { playing = LikelyPlaying(target); checked = YES; }
                    if (!playing) continue;
                }
                gEntries[i].pushes++;
                Write(&gEntries[i], target, rate);
            }
        }
    }
}

static BOOL Playerish(NSString *name) {
    return [name containsString:@"Player"] || [name containsString:@"Engine"] ||
           [name containsString:@"Speed"];
}

static void Discover(void) {
    if (gDiscovered) return;
    gDiscovered = YES;

    // 同一个祖先类只扫一次；用类指针做 key，重名类不会被误跳过
    NSMutableSet *visited = [NSMutableSet set];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        if (!Playerish(NSStringFromClass(classes[i]))) continue;

        for (Class c = classes[i]; c; c = class_getSuperclass(c)) {
            NSValue *owner = [NSValue valueWithPointer:(__bridge void *)c];
            if ([visited containsObject:owner]) break;
            [visited addObject:owner];

            unsigned int n = 0;
            Method *methods = class_copyMethodList(c, &n);
            for (unsigned int j = 0; j < n; j++) {
                SEL sel = method_getName(methods[j]);
                if (!Interesting(sel)) continue;
                int kind = KindFor(methods[j]);
                if (kind >= 0) InstallEntry(c, sel, methods[j], kind);
                else gSkipped++;
            }
            free(methods);
        }
    }
    free(classes);
}

static NSArray<NSString *> *SpeedSelectorsOf(id obj) {
    NSMutableArray *out = [NSMutableArray array];
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *methods = class_copyMethodList(c, &n);
        for (unsigned int j = 0; j < n && out.count < 40; j++) {
            const char *name = sel_getName(method_getName(methods[j]));
            if (HasSpeedWord(name)) [out addObject:[NSString stringWithUTF8String:name]];
        }
        free(methods);
    }
    return out;
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

// 长按：先报"红果真的调了什么"，再列这个实例上所有带 speed 的方法（再长按翻页）
- (void)showScan:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    Discover();
    NSArray *targets;
    NSString *last;
    @synchronized (gPlayers) { targets = gPlayers.allObjects; last = gLastWrite; }

    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"hook %d | 实例 %lu | 跳过 %d",
                                   gEntryCount, (unsigned long)targets.count, gSkipped]];
    [lines addObject:last ?: @"红果没走过任何被挂的方法"];
    for (NSUInteger i = 0; i < targets.count && i < 2; i++) {
        [lines addObject:[NSString stringWithFormat:@"实例%lu %@",
                                       (unsigned long)(i + 1), NSStringFromClass(object_getClass(targets[i]))]];
    }

    int order[kMaxEntries];
    int n = 0;
    for (int i = 0; i < gEntryCount; i++) {
        if (gEntries[i].hits + gEntries[i].pushes == 0) continue;
        int j = n++;
        while (j > 0 && gEntries[order[j - 1]].hits < gEntries[i].hits) { order[j] = order[j - 1]; j--; }
        order[j] = i;
    }
    for (int i = 0; i < n && i < 8; i++) {
        HGEntry *e = &gEntries[order[i]];
        [lines addObject:[NSString stringWithFormat:@"%@.%@ 调%d 推%d",
                                       NSStringFromClass(e->cls), NSStringFromSelector(e->setter),
                                       e->hits, e->pushes]];
    }
    if (n == 0) [lines addObject:@"没有任何挂点被调用或推送过"];

    if (targets.count) {
        NSArray<NSString *> *sels = SpeedSelectorsOf(targets[0]);
        NSUInteger start = (_scanPage * 5) % (sels.count + 1);
        for (NSUInteger i = start; i < sels.count && i < start + 5; i++) {
            [lines addObject:[NSString stringWithFormat:@"· %@", sels[i]]];
        }
        _scanPage++;
    }

    if (!gReport) {
        gReport = [[UILabel alloc] initWithFrame:CGRectMake(12, 60, 300, 320)];
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
