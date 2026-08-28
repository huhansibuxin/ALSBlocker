// ALSBlocker — v1.5.0（SpringBoard only，路线C 修复版）
//
// 背景：路线A（hook CBColorModuleiOS 钉 _dropALSColorSamples）已实锤死路：
//   - backboardd 注入 -> 崩/砖（无安全模式）；
//   - SpringBoard 注入 -> 模块不在 SpringBoard 实例化，hook 永不触发（日志铁证）。
// 活的真·调色模块在 backboardd；SpringBoard 只持有 CoreBrightness 客户端
// CBClient -> _adaptationClient（CBAdaptationClient）。
//
// 本版（路线C）：在 SpringBoard 内用 CBAdaptationClient 客户端 API
// 强制 setEnabled:NO 关掉环境光适配（= 关 True Tone），发 Framework 级命令给
// backboardd 模块，不 hook、不写 ivar、不碰 backboardd -> 绝不变砖。
//
// v1.5.0 修复（针对 v1.4.0 崩溃，精确根因）：
//   v1.4.0 崩溃栈 = ALSProbeRun+396 -> objc_retain -> SIGSEGV @0x1。
//   原因：class-dump 把 supported/getEnabled/setEnabled: 全标成 (id)（types unknown），
//   我按 (id) 声明调用，但实际 supported 返回 BOOL 标量(=1)，ARC 按对象 retain 该 1 -> 崩。
//   修复：一律用显式 objc_msgSend + 标量(BOOL/NSInteger)签名调用，杜绝 ARC 误 retain 标量。
//   （init / adaptationClient 返回真对象，按 (id) 声明没问题，保留。）
//
// v1.4.0 已解决的时序问题：全部 CoreBrightness 客户端调用推迟到主队列延迟 3s
// （SpringBoard 完全启动、客户端就绪后）执行，%ctor 绝不碰 CoreBrightness。
//
// 仅注入 SpringBoard（安全模式兜底）。文件 kill-switch：/var/jb/tmp/alsblocker.disable。
// 启动即清空旧日志，避免与上一版混淆。

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>

static NSString *ALSLogPath(void) {
    return @"/var/jb/tmp/alsblocker.log";
}

static void ALSLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [NSDate date], [[NSProcessInfo processInfo] processName], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:ALSLogPath()];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (NSException *e) {}
        [fh closeFile];
    } else {
        [line writeToFile:ALSLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static BOOL ALSBlockerDisabled(void) {
    return access("/var/jb/tmp/alsblocker.disable", F_OK) == 0;
}

// CBClient 的 init / adaptationClient 返回真对象，按 (id) 声明即可。
@interface CBClient : NSObject
- (id)init;
- (id)adaptationClient;
@end

// CBAdaptationClient 的 supported/getEnabled/setEnabled: 在运行期返回/接受标量(BOOL)。
// 绝不能用 (id) 声明去调（v1.4.0 因此 SIGSEGV）。这里用显式 objc_msgSend + 标量签名，
// 让编译器生成正确的 ARM64 调用约定，且规避 ARC 对返回值的自动 retain。
static BOOL CBAdapt_supported(id client) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(client, @selector(supported));
}
static BOOL CBAdapt_getEnabled(id client) {
    return ((BOOL (*)(id, SEL))objc_msgSend)(client, @selector(getEnabled));
}
static BOOL CBAdapt_setEnabled(id client, BOOL v) {
    return ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(client, @selector(setEnabled:), v);
}

static id sAdaptationClient = nil;

// 强制关掉环境光适配（True Tone）。纯客户端 API 调用，不碰 backboardd / 不写 ivar。
static void ALSApplyDisable(void) {
    @try {
        if (!sAdaptationClient) return;
        BOOL sup = CBAdapt_supported(sAdaptationClient);
        if (!sup) {
            ALSLog(@"adaptation NOT supported -> cannot disable via client");
            return;
        }
        BOOL ok = CBAdapt_setEnabled(sAdaptationClient, NO);   // 关 True Tone / 环境光适配
        BOOL now = CBAdapt_getEnabled(sAdaptationClient);
        ALSLog(@"setEnabled(NO) ok=%d -> getEnabled=%d (expect 0)", ok, now);
    } @catch (id e) {
        ALSLog(@"ALSApplyDisable EXC %@", e);
    }
}

// 核心探针逻辑：全部 CoreBrightness 客户端调用集中在此，且仅在 SpringBoard 启动后执行。
static void ALSProbeRun(void) {
    ALSLog(@"deferred probe fired (SpringBoard launched) — begin client API probe");
    @try {
        Class cbCls = NSClassFromString(@"CBClient");
        if (!cbCls) { ALSLog(@"CBClient class NOT found"); return; }
        ALSLog(@"CBClient class found");

        id client = [[cbCls alloc] init];
        if (!client) { ALSLog(@"CBClient init returned nil"); return; }
        ALSLog(@"CBClient inited");

        sAdaptationClient = [client adaptationClient];
        if (!sAdaptationClient) { ALSLog(@"adaptationClient is nil"); return; }
        ALSLog(@"adaptationClient got");

        BOOL sup = CBAdapt_supported(sAdaptationClient);
        BOOL before = CBAdapt_getEnabled(sAdaptationClient);
        ALSLog(@"supported=%d enabledBefore=%d", sup, before);

        ALSApplyDisable();

        // 有界观察窗口：装后 60s 内每 1s 复查 enabled 是否被系统翻回（诊断用）。
        // 窗口到期自动停，不长期轮询（尊重"事件驱动、不常驻轮询"要求）。
        __block int ticks = 0;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 1 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(timer, ^{
            @try {
                BOOL en = CBAdapt_getEnabled(sAdaptationClient);
                if (en) {
                    ALSLog(@"WATCHDOG: enabled flipped back to YES -> re-assert NO");
                    ALSApplyDisable();
                }
            } @catch (id e) {}
            if (++ticks >= 60) {
                ALSLog(@"probe window ended (60s), stopping watchdog");
                dispatch_source_cancel(timer);
            }
        });
        dispatch_resume(timer);
    } @catch (id e) {
        ALSLog(@"probe EXC %@", e);
    }
}

%ctor {
    // 每次启动清空旧日志，避免与上一版混淆
    @try { [[NSFileManager defaultManager] removeItemAtPath:ALSLogPath() error:nil]; } @catch (id e) {}

    if (ALSBlockerDisabled()) {
        ALSLog(@"DISABLED via kill-switch file, not touching adaptation");
        return;
    }
    ALSLog(@"loaded (v1.5.0, route C, scalar-signature fix, deferred 3s to SpringBoard launch)");

    // 关键：绝不在 %ctor（dyld 加载期）同步碰 CoreBrightness。
    // 推迟到主队列延迟 3s，此时 SpringBoard 已完全启动、CoreBrightness 客户端已就绪。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ULL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        ALSProbeRun();
    });
}
