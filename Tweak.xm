// ALSBlocker — v1.7.0 (route C++, permanent watchdog)
//
// 背景 / 为什么是这一版：
//   - v1.6.0 尝试注入 backboardd（hook CBColorFilter.addHIDServiceClient: drop ALS），
//     但 backboardd 的 tweak 注入早被 MobileSafety 从更早 3 次崩溃起整体禁用，
//     %ctor 根本没跑过 —— 这条路已堵死，不再碰 backboardd。
//   - 本版回到 SpringBoard（有安全模式兜底），用 CoreBrightness 客户端
//     CBAdaptationClient.setEnabled:NO 强制关掉环境光适配（= 关 True Tone 色适应）。
//   - 实测（v1.5.0 探针）：setEnabled(NO) 本身有效（getEnabled 回到 0），
//     但 backboardd 的 ALS 管线每隔几秒把它翻回 YES。本版用一个**常驻低频看门狗**
//     （每 2s 复查，被翻回 YES 就立刻再钉 NO）持续按住，黄屏没机会出现。
//
// 安全设计（绝不崩、不砖）：
//   - 只注入 SpringBoard（有安全模式，最坏进安全模式卸掉）。
//   - 全部 CoreBrightness 客户端调用**延迟到 SpringBoard 启动后**（主队列 3s）执行，
//     绝不在 %ctor 同步初始化。
//   - 三个客户端方法（supported / getEnabled / setEnabled:）一律走**显式 objc_msgSend + 标量签名**，
//     杜绝 class-dump 把 BOOL 误标 (id) 导致 ARC retain 标量 (0x1) 崩溃。
//   - 文件 kill-switch：/var/jb/tmp/alsblocker.disable 存在时 %ctor 直接空跑，SSH touch 一下即可救，
//     不依赖安全模式。
//   - 看门狗每 2s 才跑一次，且仅在状态变化时写日志，开销可忽略。

#import <substrate.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

static NSString * const kLogPath = @"/var/jb/tmp/alsblocker.log";
static NSString * const kKillSwitch = @"/var/jb/tmp/alsblocker.disable";

static void ALSLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    NSString *line = [NSString stringWithFormat:@"%@ [SpringBoard] %@\n",
                      [df stringFromDate:[NSDate date]], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    }
}

// ---- 显式标量签名调用 CoreBrightness 客户端（避免 ARC 误 retain BOOL）----
static BOOL CBAdapt_supported(id c) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(c, @selector(supported));
}
static BOOL CBAdapt_getEnabled(id c) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(c, @selector(getEnabled));
}
// 返回 BOOL（实测 setEnabled: 返回 BOOL，非对象）
static BOOL CBAdapt_setEnabled(id c, BOOL v) {
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(c, @selector(setEnabled:), v);
}

static id gAdaptClient = nil;
static BOOL gActive = NO;     // 看门狗是否在跑
static BOOL gLastState = NO;  // 上次记录的 enabled 状态（用于只在变化时日志）

static void ALSReassert(void) {
    if (!gAdaptClient) return;
    BOOL en = CBAdapt_getEnabled(gAdaptClient);
    if (en == YES) {
        // 被 backboardd 翻回了 YES -> 立刻再钉死
        BOOL ok = CBAdapt_setEnabled(gAdaptClient, NO);
        if (gLastState != NO) {
            ALSLog(@"re-assert setEnabled(NO) ok=%d (was flipped back to YES)", ok);
            gLastState = NO;
        }
    } else {
        if (gLastState != NO) { gLastState = NO; } // 已为 OFF，静默
    }
}

static void ALSProbeRun(void) {
    Class cbClass = objc_getClass("CBClient");
    if (!cbClass) { ALSLog(@"CBClient class NOT found"); return; }
    ALSLog(@"CBClient class found");

    id cb = [[cbClass alloc] init];
    if (!cb) { ALSLog(@"CBClient init failed"); return; }
    ALSLog(@"CBClient inited");

    // _adaptationClient 是 CBClient 的 ivar/属性，名称取自现有 CoreBrightness.h
    id adapt = [cb valueForKey:@"_adaptationClient"];
    if (!adapt) { ALSLog(@"adaptationClient is nil"); return; }
    ALSLog(@"adaptationClient got");

    gAdaptClient = adapt;

    BOOL supported = CBAdapt_supported(adapt);
    BOOL enabledBefore = CBAdapt_getEnabled(adapt);
    ALSLog(@"supported=%d enabledBefore=%d", supported, enabledBefore);

    // 初次强制关掉
    BOOL ok = CBAdapt_setEnabled(adapt, NO);
    BOOL after = CBAdapt_getEnabled(adapt);
    ALSLog(@"initial setEnabled(NO) ok=%d -> getEnabled=%d (expect 0)", ok, after);
    gLastState = after;

    // 常驻看门狗：每 2s 复查，被翻回 YES 就再钉 NO
    gActive = YES;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        if (!gActive) return;
        @try { ALSReassert(); }
        @catch (...) {}
    });
    dispatch_resume(timer);
    ALSLog(@"permanent watchdog started (re-assert every 2s)");
}

__attribute__((constructor)) static void _logosLocalCtor(void) {
    // 清旧日志（保留本次会话）
    [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:nil];

    if ([[NSFileManager defaultManager] fileExistsAtPath:kKillSwitch]) {
        ALSLog(@"v1.7.0 loaded but DISABLED by kill-switch (%@)", kKillSwitch);
        return; // 空跑，不挂客户端、不启动看门狗
    }
    ALSLog(@"v1.7.0 loaded (route C++ permanent watchdog, SpringBoard-only)");

    // 关键：延迟到 SpringBoard 完全启动后再碰 CoreBrightness 客户端，
    // 绝不在构造期（dyld 加载期）初始化 -> 避免 EXC_BAD_ACCESS。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        @try { ALSProbeRun(); }
        @catch (...) { ALSLog(@"ALSProbeRun threw, swallowed"); }
    });
}
