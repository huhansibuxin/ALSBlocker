// ALSBlocker — 探针版 v1.4.0（SpringBoard only，路线C 验证，延迟执行修复）
//
// 背景：路线A（hook CBColorModuleiOS 钉 _dropALSColorSamples）已实锤死路：
//   - backboardd 注入 -> 崩/砖（无安全模式）；
//   - SpringBoard 注入 -> 模块不在 SpringBoard 实例化，hook 永不触发（日志铁证）。
// 活的真·调色模块在 backboardd；SpringBoard 只持有 CoreBrightness 客户端
// CBClient -> _adaptationClient（CBAdaptationClient）。
//
// 本版（路线C 探针）：在 SpringBoard 内用 CBAdaptationClient 客户端 API
// 强制 setEnabled:NO 关掉环境光适配（= 关 True Tone），发 Framework 级命令给
// backboardd 模块，不 hook、不写 ivar、不碰 backboardd -> 绝不变砖。
//
// v1.4.0 修复（针对 v1.3.0 崩溃）：
//   v1.3.0 在 %ctor（dyld 加载期）同步初始化 CBClient，此时 SpringBoard 尚未启动、
//   CoreBrightness 客户端 XPC 未就绪，拿到野指针 -> objc_retain -> SIGSEGV -> 进安全模式。
//   本版把全部 CoreBrightness 客户端调用移出 %ctor，推迟到主队列延迟 3s 执行
//   （SpringBoard 已完全启动、客户端已就绪）。%ctor 本身绝不碰 CoreBrightness。
//
// 仅注入 SpringBoard（安全模式兜底）。文件 kill-switch：/var/jb/tmp/alsblocker.disable。
// 启动即清空旧日志，避免与上一版混淆。

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/runtime.h>
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

// 客户端 API 前向声明（CoreBrightness 私有，无公开头；签名取自设备 CoreBrightness.h：
// setEnabled:/getEnabled 返回与参数均为 id/NSNumber，故 @(NO) 与 boolValue 正确）。
@interface CBAdaptationClient : NSObject
- (id)setEnabled:(id)arg0;
- (id)getEnabled;
- (id)supported;
- (id)getAdaptationMode;
@end

@interface CBClient : NSObject
- (id)init;
- (id)adaptationClient;
@end

static id sAdaptationClient = nil;

// 强制关掉环境光适配（True Tone）。纯客户端 API 调用，不碰 backboardd / 不写 ivar。
static void ALSApplyDisable(void) {
    @try {
        if (!sAdaptationClient) return;
        id sup = [sAdaptationClient supported];
        if (sup && ![sup boolValue]) {
            ALSLog(@"adaptation NOT supported -> cannot disable via client");
            return;
        }
        [sAdaptationClient setEnabled:@(NO)];  // 关 True Tone / 环境光适配
        id now = [sAdaptationClient getEnabled];
        ALSLog(@"setEnabled(NO) -> getEnabled=%@ (expect 0)", now);
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

        id sup = [sAdaptationClient supported];
        id before = [sAdaptationClient getEnabled];
        ALSLog(@"supported=%@ enabledBefore=%@ mode=%@", sup, before, [sAdaptationClient getAdaptationMode]);

        ALSApplyDisable();

        // 有界观察窗口：装后 15s 内每 1s 复查 enabled 是否被系统翻回（诊断用）。
        // 窗口到期自动停，不长期轮询（尊重"事件驱动、不常驻轮询"要求）。
        __block int ticks = 0;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), 1 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(timer, ^{
            @try {
                id en = [sAdaptationClient getEnabled];
                if (en && [en boolValue]) {
                    ALSLog(@"WATCHDOG: enabled flipped back to YES -> re-assert NO");
                    ALSApplyDisable();
                }
            } @catch (id e) {}
            if (++ticks >= 15) {
                ALSLog(@"probe window ended (15s), stopping watchdog");
                dispatch_source_cancel(timer);
            }
        });
        dispatch_resume(timer);
    } @catch (id e) {
        ALSLog(@"probe EXC %@", e);
    }
}

%ctor {
    // 每次启动清空旧日志，避免与上一版混淆（老板要求：更新版本清旧日志）
    @try { [[NSFileManager defaultManager] removeItemAtPath:ALSLogPath() error:nil]; } @catch (id e) {}

    if (ALSBlockerDisabled()) {
        ALSLog(@"DISABLED via kill-switch file, not touching adaptation");
        return;
    }
    ALSLog(@"loaded (probe v1.4.0, route C, deferred 3s to SpringBoard launch)");

    // 关键修复：绝不在 %ctor（dyld 加载期）同步碰 CoreBrightness。
    // 推迟到主队列延迟 3s，此时 SpringBoard 已完全启动、CoreBrightness 客户端已就绪。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3ULL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        ALSProbeRun();
    });
}
