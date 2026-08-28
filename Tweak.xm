// ALSBlocker — v1.6.0（backboardd-only，源头禁用 ALS）
//
// 背景复盘：
//   路线A（hook CBColorModuleiOS 钉 _dropALSColorSamples）：backboardd 注入崩/砖；SpringBoard 注入永不触发。
//   路线C（SpringBoard 客户端 setEnabled:NO + 看门狗）：API 通、不崩，但被 backboardd 实时翻回，屏仍黄。
//   白点冻结：API 不暴露在 CBClient 上，够不到。
// => SpringBoard 侧所有杠杆都赢不了 backboardd 的 ALS 实时管线。
//
// 唯一真·根治：让 backboardd 收不到 ALS 光。
// 做法（v1.6.0）：在 backboardd 内 hook CBColorFilter.addHIDServiceClient:，
// 用 ALSServiceConformsToPolicy: 判断该 HID 服务是否 ALS，是则 return nil
// （不注册该服务 -> backboardd 再也收不到环境光 -> 白点恒定、不再随光变黄）。
//
// 安全设计（避免再次变砖）：
//   1) 纯方法 hook，不碰任何 ivar、不在 %ctor 初始化 CoreBrightness（v1.0 崩的根因）。
//   2) %group + %ctor 控制：kill-switch 文件存在时，%ctor 直接 return 不 %init
//      -> hook 完全不注册，dylib 空跑，等于没装。SSH `touch /var/jb/tmp/alsblocker.disable` 即救。
//   3) ALSServiceConformsToPolicy: 用标量(BOOL)签名 objc_msgSend 调用，杜绝 ARC retain 标量崩溃（v1.5 教训）。
//   4) 启动清空旧日志（老板要求每次更新清上一版日志）。

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <unistd.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *kLogPath  = @"/var/jb/tmp/alsblocker.log";
static NSString *kKillPath = @"/var/jb/tmp/alsblocker.disable";

static void ALSLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [NSDate date], [[NSProcessInfo processInfo] processName], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (fh) {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (NSException *e) {}
        [fh closeFile];
    } else {
        [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static BOOL ALSKillEnabled(void) {
    return access(kKillPath.UTF8String, F_OK) == 0;
}

// ALSServiceConformsToPolicy: 运行期返回 BOOL 标量（头里标 (id) / types unknown）。
// 用标量签名调，规避 ARC 自动 retain 返回值（v1.5 SIGSEGV 教训）。
static BOOL CBColorFilter_isALS(id self, id service) {
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(self, @selector(ALSServiceConformsToPolicy:), service);
}

%group ALSBlockerBB

%hook CBColorFilter

// HID 服务注册入口。ALS 服务在此经过；drop 它则 backboardd 再也收不到环境光。
- (id)addHIDServiceClient:(id)service {
    if (ALSKillEnabled()) return %orig;
    BOOL isALS = NO;
    @try { isALS = CBColorFilter_isALS(self, service); }
    @catch (id e) { isALS = NO; }
    if (isALS) {
        ALSLog(@"drop ALS HID service client -> backboardd will not receive ambient light");
        return nil;  // 不注册该服务
    }
    return %orig;
}

%end

%end  // group ALSBlockerBB

%ctor {
    // 清旧日志
    @try { [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:nil]; } @catch (id e) {}

    if (ALSKillEnabled()) {
        // 最强软禁用：不 %init -> hook 完全不注册 -> dylib 空跑，等于没装。
        // 恢复：SSH `rm /var/jb/tmp/alsblocker.disable` 后 killall backboardd
        [@"[backboardd] DISABLED by kill-switch, hooks not registered\n" writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    ALSLog(@"loaded (v1.6.0, backboardd-only, CBColorFilter.addHIDServiceClient drop ALS)");
    %init(ALSBlockerBB);
}
