#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
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
// v5 实测：`hook 445 | 实例 6 | 跳过 414 | 溢出 0` —— 真播放器现形：
//          TTVideoEngineOwnPlayer.setPlayerPlaybackSpeed: 调17 推0、.setPlaybackSpeed: 调11 推0。
//          调了但推不到，说明它没被登记成可写对象：对象参数型的 setter 不 Track，且它多半收的是 NSNumber。
// v6：① 对象参数也登记调用者，且传进来是 NSNumber 时按倍速代写；② 每个挂点自己记住"最近调用者类 /
//        最近数值 / 最近传入对象类"，不再用全局"最后一次写入"（会被每秒刷几十次的网速接口盖掉）；
//     ③ 只往播放倍速上写（方法名含 play 或接收者是播放器类），不再污染 setNetSpeed: 这类网速接口；
//     ④ play/start 不再挂到 NSOperation 这类通用祖先类上（实测调 736 次全是噪音）；
//     ⑤ Track 只收名字像播放器的对象，40 个名额不被杂项占满；⑥ 面板翻页改成列"最像播放器那个类"的 speed 方法。
// v7：倍率补齐成红果自己菜单里的全部档位 —— 0.75 / 1.0 / 1.25 / 1.5 / 2.0 / 3.0。
//     顺序 1 → 1.25 → 1.5 → 2 → 3 → 0.75 → 1；0 号位仍是 1.0（"不干预"档），语义不变。
// v7 真机反馈两个问题：① 起播时"有声音但黑屏，过一会才出画面"；② 每次打开都回到 1.0，要记忆上次档位。
// v8：① 黑屏的根因是那次全类扫描在主线程上跑（几万个类 + 每个方法 malloc 类型串），把主线程卡住 →
//        首帧提交不了。扫描整个搬到后台队列，主线程只负责建浮钮；面板第一行加"扫 X ms"以便复核耗时。
//     ② 档位存进 NSUserDefaults（键 HGSpeedRate），下次启动直接恢复；恢复后不用点圆钮 —— 一旦有播放器
//        对象被登记出来，就自动补写一次当前倍率。
//     ③ 顺带把挂点数组的发布顺序改成"先填内容、最后写 cls"，后台扫描与红果自己的调用并发时不会读到半条记录。

static const float kRates[] = { 1.0f, 1.25f, 1.5f, 2.0f, 3.0f, 0.75f };
static const int kRateCount = 6;
static int gRateIndex = 0;

enum { kKindDouble, kKindFloat, kKindIntPercent, kKindObject, kKindLogVoid, kKindTrack };

typedef struct {
    Class cls;
    SEL setter;
    IMP orig;
    int kind;
    int hits;
    int pushes;
    int numberArg;    // 对象参数实测是 NSNumber，可以按倍速代写
    Class recv;       // 最近一次调用者对象的类
    double val;       // 最近一次调用时的数值
    Class arg;        // 对象参数时，最近一次传进来的对象的类
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
static volatile BOOL gFreshPlayer = NO;   // 有新播放器被登记出来 → 主线程补写一次当前倍率
static volatile BOOL gScanning = NO;
static volatile int gScanMs = 0;

static UIWindow *KeyWindow(void);
static void EnsureBadge(void);

static float CurRate(void) { return kRates[gRateIndex]; }
static BOOL Forcing(void) { return gRateIndex != 0; }

// 上次的档位存在用户偏好里；认不出来（没存过、或那个档位以后被删了）就回到 1.0 不干预
static void LoadRate(void) {
    double saved = [[NSUserDefaults standardUserDefaults] doubleForKey:@"HGSpeedRate"];
    gRateIndex = 0;
    for (int i = 1; i < kRateCount; i++) {
        if (fabs(kRates[i] - saved) < 0.001) { gRateIndex = i; return; }
    }
}

static void SaveRate(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:CurRate() forKey:@"HGSpeedRate"];
    [d synchronize];
}

// 选择器名/类名都是 ASCII，忽略大小写找子串不必走 NSString，也不会像定长缓冲区那样截断长名字
static BOOL ContainsIC(const char *hay, const char *lowerNeedle) {
    for (; *hay; hay++) {
        const char *h = hay, *n = lowerNeedle;
        while (*n && *h) {
            char c = (*h >= 'A' && *h <= 'Z') ? (char)(*h + 32) : *h;
            if (c != *n) break;
            h++; n++;
        }
        if (!*n) return YES;
    }
    return NO;
}

static BOOL Playerish(const char *name) {
    return strstr(name, "Player") || strstr(name, "Engine") || strstr(name, "Speed");
}

// 只登记"名字像播放器"的对象：红果里每个 speed setter 的调用者都塞进来的话，40 个名额
// 会被网速采样、DNS 探测这类杂项占满，真正的播放器反而挤不进来。
#define kMaxTracked 40
static void Track(id obj) {
    Class cls = object_getClass(obj);
    if (!Playerish(class_getName(cls))) return;
    @synchronized (gPlayers) {
        NSUInteger before = gPlayers.count;
        if (before < kMaxTracked) [gPlayers addObject:obj];
        // 第一次见到这个对象：让主线程稍后把当前倍率补写上去（恢复记忆时不用用户再点一下）
        if (gPlayers.count > before) gFreshPlayer = YES;
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
        case kKindObject:
            ((void (*)(id, SEL, id))entry->orig)(target, sel, @(rate));
            break;
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
    entry->recv = object_getClass(self);
    entry->val = value;
    Write(entry, self, (float)value);
}

static void HK_set_float(id self, SEL _cmd, float value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    if (Forcing() && fabsf(value - 1.0f) < 0.001f) value = CurRate();
    entry->recv = object_getClass(self);
    entry->val = value;
    Write(entry, self, value);
}

static void HK_set_intpercent(id self, SEL _cmd, int value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    float rate = value / 100.0f;
    if (Forcing() && value == 100) rate = CurRate();
    entry->recv = object_getClass(self);
    entry->val = rate;
    Write(entry, self, rate);
}

// 对象参数：只有一种情况会代写 —— 红果自己传进来的就是 NSNumber，那倍速肯定是数字语义
static void HK_set_object(id self, SEL _cmd, id value) {
    Track(self);
    HGEntry *entry = Match(self, _cmd);
    if (!entry) return;
    entry->hits++;
    entry->recv = object_getClass(self);
    entry->arg = value ? object_getClass(value) : nil;
    if ([value isKindOfClass:NSNumber.class]) {
        entry->numberArg = 1;
        entry->val = [value doubleValue];
        if (Forcing() && fabs(entry->val - 1.0) < 0.001) value = @(CurRate());
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

// 只往"播放倍速"上写。红果里网速采样、端口探测这类接口也叫 setXxxSpeed:，
// 往那些上面写倍速只会污染它的测速模型，所以要求方法名带 play、或接收者本身是播放器类。
static BOOL Pushable(HGEntry *entry) {
    if (!NumericKind(entry->kind) && !(entry->kind == kKindObject && entry->numberArg)) return NO;
    return ContainsIC(sel_getName(entry->setter), "play")
        || ContainsIC(class_getName(entry->cls), "player");
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
    // 扫描搬到后台线程后，这里必须保证"整条记录先落地、再让别的线程看见 gEntryCount"，
    // 否则红果的调用可能读到一条 orig 还是空壳的记录。
    __sync_synchronize();
    gEntryCount++;
}

static const char *kRateNames[] = {
    "setRate:", "setPlaybackRate:", "setPlayRate:", "setTimeRate:", "updateRate:", "setRateValue:"
};
static const char *kPlayNames[] = { "play", "start", "playOrResume", "resumePlay" };

static BOOL HasSpeedWord(const char *name) {
    return ContainsIC(name, "speed");
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
                if (gEntries[i].cls != c || !Pushable(&gEntries[i])) continue;
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

// 真正的扫描。几万个类、每个方法都要 malloc 一次类型串，**绝不能放在主线程上跑**
// （v7 就是卡在这里：主线程一停，首帧提交不了 → 有声音但黑屏）。
static void ScanAll(void) {
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
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
                // play/start 只在名字就像播放器的类上挂。沿继承链挂到 NSOperation.start 会把全 App
                // 的后台任务都登记成"播放器实例"（实测调 736 次），噪音盖住真目标。
                if (kind == kKindTrack && !Playerish(class_getName(c))) kind = -1;
                if (kind >= 0) InstallEntry(c, sel, methods[j], kind);
                else gSkipped++;
            }
            free(methods);
        }
    }
    free(classes);
    HookApp();
    gScanMs = (int)((CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
    gScanning = NO;
}

// 红果的播放器类可能比浮钮更晚加载（懒加载的 framework），所以可以反复调用：
// gVisited 记着扫过哪个类，重扫只会处理新出现的类。扫描本身丢到后台队列，主线程不等待。
static void Discover(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gDiscovered && now - gLastScan < 2.0) return;
    gDiscovered = YES;
    gLastScan = now;
    if (gScanning) return;
    gScanning = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ ScanAll(); });
}

static NSArray<NSString *> *SpeedSelectorsOf(Class start) {
    NSMutableArray *out = [NSMutableArray array];
    for (Class c = start; c; c = class_getSuperclass(c)) {
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
    SaveRate();
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
    NSString *note = nil;
    Class noteObj = nil;
    int noteHits = 0, taps = 0, tapSeq = 0;
    @synchronized (gPlayers) {
        targets = gPlayers.allObjects;
        note = gNoteName; noteObj = gNoteObject; noteHits = gNoteHits;
        taps = gTapCount; tapSeq = gTapNext;
    }

    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"hook %d | 实例 %lu | 跳过 %d | 溢出 %d | 扫 %d ms",
                                   gEntryCount, (unsigned long)targets.count, gSkipped, gDropped, gScanMs]];

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
    for (NSUInteger i = 0; i < targets.count && i < 4; i++) {
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
        NSMutableString *s = [NSMutableString stringWithFormat:@"%@.%@ 调%d 推%d",
                                       NSStringFromClass(e->cls), NSStringFromSelector(e->setter),
                                       e->hits, e->pushes];
        if (e->recv && e->recv != e->cls) [s appendFormat:@" 于%@", NSStringFromClass(e->recv)];
        if (e->kind == kKindObject) {
            if (e->arg) [s appendFormat:@" 收%@", NSStringFromClass(e->arg)];
        } else if (e->val != 0) {
            [s appendFormat:@" =%.3g", e->val];
        }
        [lines addObject:s];
    }
    if (n == 0) [lines addObject:@"没有任何挂点被调用或推送过"];

    // 翻页看"最像播放器的那个被调类"上还有哪些带 speed 的方法（这才是下一版要挂的目标）
    Class probe = Nil;
    for (int i = 0; i < n && !probe; i++) {
        Class r = gEntries[order[i]].recv ?: gEntries[order[i]].cls;
        if (ContainsIC(class_getName(r), "player")) probe = r;
    }
    if (!probe && n) probe = gEntries[order[0]].recv ?: gEntries[order[0]].cls;
    if (!probe && targets.count) probe = object_getClass(targets[0]);
    if (probe) {
        NSArray<NSString *> *sels = SpeedSelectorsOf(probe);
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
    // 刚登记出一个新播放器（可能是恢复记忆后红果第一次起播）→ 把当前倍率补写上去
    if (gFreshPlayer) {
        gFreshPlayer = NO;
        if (Forcing()) ApplyAll(CurRate());
    }
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
    LoadRate();

    // 挂点延迟到浮钮第一次出现时才装（那时 App 的播放器类已经全部加载完）
    CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(NULL,
        CFAbsoluteTimeGetCurrent() + 1.0, 0.5, 0, 0, ^(CFRunLoopTimerRef t) { EnsureBadge(); });
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
}
