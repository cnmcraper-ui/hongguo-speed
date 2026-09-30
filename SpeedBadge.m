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
// v4 实测：面板 `hook 96 | 实例 2 | 跳过 414`，只有三个 .start 记到调用（TTVideoEngineBatteryMonitor /
//          TTVideoEngineCFHostDNS / OHREngine），倍速相关的全是 0。而 96 正好等于 gEntries 数组上限
//          → 挂点被静默截断，真正的 setter 很可能排在后面没挂上；认出来的"实例"也是名字带 Engine 的杂项类。
// v5：① 上限 96 → 1024，并单列"溢出"计数，被截断时面板会显示；② 挂点改为可重扫，晚加载的类也能补上；
//     ③ 加两个"问路"探针：UIApplication sendAction:（记录每次点按钮打到哪个类的哪个方法）和
//        名字含 speed 的通知（记录是谁用通知传倍速）。这样即使挂点仍没命中，也能直接看到红果的倍速入口叫什么。

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

#define kMaxEntries 1024
static HGEntry gEntries[kMaxEntries];
static int gEntryCount = 0;
static int gSkipped = 0;
static int gDropped = 0;
static BOOL gDiscovered = NO;
static CFAbsoluteTime gLastScan = 0;
static NSMutableSet *gVisited = nil;
static NSHashTable *gPlayers = nil;
static UIView *gBadge = nil;
static UILabel *gReport = nil;

static UIWindow *KeyWindow(void);
static void EnsureBadge(void);

static float CurRate(void) { return kRates[gRateIndex]; }
static BOOL Forcing(void) { return gRateIndex != 0; }

#define kMaxTracked 40
static void Track(id obj) {
    @synchronized (gPlayers) {
        if (gPlayers.count < kMaxTracked) [gPlayers addObject:obj];
    }
}

// 最后一次写入只存指针和数值，格式化推到面板里做：挂点扩到 512 之后，
// 每调一次就 alloc 一个 NSString 会给播放线程添负担。
static Class gLastCls = nil;
static SEL gLastSel = NULL;
static double gLastVal = 0;
static Class gLastArgCls = nil;

static void Note(id obj, SEL sel, double value) {
    @synchronized (gPlayers) {
        gLastCls = object_getClass(obj);
        gLastSel = sel;
        gLastVal = value;
        gLastArgCls = nil;
    }
}

static void NoteObject(id obj, SEL sel, id value) {
    @synchronized (gPlayers) {
        gLastCls = object_getClass(obj);
        gLastSel = sel;
        gLastVal = 0;
        gLastArgCls = value ? object_getClass(value) : nil;
    }
}

#define kMaxTaps 6
static SEL gTapAction[kMaxTaps];
static Class gTapTarget[kMaxTaps];
static int gTapCount = 0;
static int gTapNext = 0;

static NSString *gNoteName = nil;
static Class gNoteObject = nil;
static int gNoteHits = 0;

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
    NoteObject(self, _cmd, value);
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
    for (int i = 0; i < gEntryCount; i++) {
        if (gEntries[i].cls == cls && gEntries[i].setter == sel) return;
    }
    if (gEntryCount == kMaxEntries) { gDropped++; return; }
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

// —— 两个"问路"探针：万一倍速 setter 还是没命中，从"点了按钮打到哪个方法"和"谁发了带 speed 的通知"
//    也能直接看到红果的倍速入口叫什么名字。只记录，不改行为。

static IMP gOrigSendAction = NULL;
static IMP gOrigPost2 = NULL;
static IMP gOrigPost3 = NULL;

static void HookOne(Class cls, SEL sel, IMP wrapper, IMP *saveOrig) {
    Method m = class_getInstanceMethod(cls, sel);   // 含继承，拿到的是真正声明它的那个
    if (!m) return;
    *saveOrig = method_setImplementation(m, wrapper);
}

static BOOL HK_sendAction(id self, SEL _cmd, SEL action, id target, id sender, UIEvent *event) {
    if (action && target) {
        int slot = gTapNext % kMaxTaps;
        gTapAction[slot] = action;
        gTapTarget[slot] = object_getClass(target);
        gTapNext++;
        if (gTapCount < kMaxTaps) gTapCount++;
    }
    if (!gOrigSendAction) return NO;
    return ((BOOL (*)(id, SEL, SEL, id, id, UIEvent *))gOrigSendAction)(self, _cmd, action, target, sender, event);
}

// 通知是全 App 都在刷的热路径，这里只用 rangeOfString 判断、不转 UTF-8，避免每次 post 都产生临时字符串
static BOOL SpeedNamed(NSString *name) {
    return name && [name rangeOfString:@"peed"].location != NSNotFound;
}

static void HK_post2(id self, SEL _cmd, NSString *name, id object) {
    if (SpeedNamed(name)) {
        @synchronized (gPlayers) { gNoteName = name; gNoteObject = object ? object_getClass(object) : nil; gNoteHits++; }
    }
    if (gOrigPost2) ((void (*)(id, SEL, NSString *, id))gOrigPost2)(self, _cmd, name, object);
}

static void HK_post3(id self, SEL _cmd, NSString *name, id object, NSDictionary *userInfo) {
    if (SpeedNamed(name)) {
        @synchronized (gPlayers) { gNoteName = name; gNoteObject = object ? object_getClass(object) : nil; gNoteHits++; }
    }
    if (gOrigPost3) ((void (*)(id, SEL, NSString *, id, NSDictionary *))gOrigPost3)(self, _cmd, name, object, userInfo);
}

static void HookApp(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    HookOne(UIApplication.class, @selector(sendAction:to:from:forEvent:), (IMP)HK_sendAction, &gOrigSendAction);
    Class center = object_getClass(NSNotificationCenter.defaultCenter);
    HookOne(center, @selector(postNotificationName:object:), (IMP)HK_post2, &gOrigPost2);
    HookOne(center, @selector(postNotificationName:object:userInfo:), (IMP)HK_post3, &gOrigPost3);
}

static BOOL Playerish(const char *name) {
    return strstr(name, "Player") || strstr(name, "Engine") || strstr(name, "Speed");
}

// 红果的播放器类可能比浮钮更晚加载（懒加载的 framework），所以这个函数可以反复调用：
// gVisited 记着扫过哪个类，重扫只会处理新出现的类。
static void Discover(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gDiscovered && now - gLastScan < 2.0) return;
    gDiscovered = YES;
    gLastScan = now;

    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        if (!Playerish(class_getName(classes[i]))) continue;

        for (Class c = classes[i]; c; c = class_getSuperclass(c)) {
            NSValue *owner = [NSValue valueWithPointer:(__bridge void *)c];
            if ([gVisited containsObject:owner]) break;
            [gVisited addObject:owner];

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
    HookApp();
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

// 长按：报"红果真的调了什么"+"点了按钮打到哪"+"有没有走通知"，再翻页列实例上的 speed 方法
- (void)showScan:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    Discover();
    NSArray *targets;
    NSString *last = nil, *note = nil;
    Class noteObj = nil;
    int noteHits = 0, taps = 0, tapSeq = 0;
    @synchronized (gPlayers) {
        targets = gPlayers.allObjects;
        if (gLastSel) {
            last = gLastArgCls
                ? [NSString stringWithFormat:@"写 %@ %@<- %@", NSStringFromClass(gLastCls),
                                       NSStringFromSelector(gLastSel), NSStringFromClass(gLastArgCls)]
                : [NSString stringWithFormat:@"写 %@ %@=%.3g", NSStringFromClass(gLastCls),
                                       NSStringFromSelector(gLastSel), gLastVal];
        }
        note = gNoteName; noteObj = gNoteObject; noteHits = gNoteHits;
        taps = gTapCount; tapSeq = gTapNext;
    }

    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"hook %d | 实例 %lu | 跳过 %d | 溢出 %d",
                                   gEntryCount, (unsigned long)targets.count, gSkipped, gDropped]];
    [lines addObject:last ?: @"红果没走过任何被挂的方法"];

    int shown = taps < 3 ? taps : 3;
    for (int i = shown; i >= 1; i--) {
        int slot = (tapSeq - i) % kMaxTaps;
        [lines addObject:[NSString stringWithFormat:@"按 %@ %@",
                                       gTapTarget[slot] ? NSStringFromClass(gTapTarget[slot]) : @"?",
                                       NSStringFromSelector(gTapAction[slot])]];
    }
    if (noteHits) {
        [lines addObject:[NSString stringWithFormat:@"通知 %@ ×%d %@", note, noteHits,
                                       noteObj ? NSStringFromClass(noteObj) : @"(无对象)"]];
    }
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
    for (int i = 0; i < n && i < 6; i++) {
        HGEntry *e = &gEntries[order[i]];
        [lines addObject:[NSString stringWithFormat:@"%@.%@ 调%d 推%d",
                                       NSStringFromClass(e->cls), NSStringFromSelector(e->setter),
                                       e->hits, e->pushes]];
    }
    if (n == 0) [lines addObject:@"没有任何挂点被调用或推送过"];

    if (targets.count) {
        NSArray<NSString *> *sels = SpeedSelectorsOf(targets[0]);
        NSUInteger start = (_scanPage * 4) % (sels.count + 1);
        for (NSUInteger i = start; i < sels.count && i < start + 4; i++) {
            [lines addObject:[NSString stringWithFormat:@"· %@", sels[i]]];
        }
        _scanPage++;
    }

    if (!gReport) {
        gReport = [[UILabel alloc] initWithFrame:CGRectMake(10, 80, 340, 470)];
        gReport.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        gReport.textColor = [UIColor whiteColor];
        gReport.font = [UIFont systemFontOfSize:9.0];
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
    gVisited = [NSMutableSet set];

    // 挂点延迟到浮钮第一次出现时才装（那时 App 的播放器类已经全部加载完）
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(NULL,
        CFAbsoluteTimeGetCurrent() + 1.0, 0.5, 0, 0, ^(CFRunLoopTimerRef t) { EnsureBadge(); });
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
}
