// ALSBlocker — 探针 + 修复版（v1.1.0）
//
// 目的：
//   1) 确认 CBColorModuleiOS 到底在 SpringBoard 还是 backboardd 被实例化（日志打印进程名）；
//   2) 在确认到的宿主里，钉死苹果自留开关 _dropALSColorSamples=YES，使 True Tone 不再随环境光变黄。
//
// 安全设计（避免再次变砖）：
//   - Filter 同时覆盖 SpringBoard + backboardd，两个进程都挂 hook，靠日志判断宿主。
//   - MSHookIvar 前先用 class_getInstanceVariable 判空：ivar 找不到就跳过，绝不写坏地址 -> 不可能 SIGSEGV。
//   - %ctor 开头查文件 kill-switch /var/jb/tmp/alsblocker.disable：万一异常，SSH `touch` 它再 reboot 即可恢复，
//     不依赖安全模式（backboardd 崩溃无安全模式兜底）。
//   - 所有动作写日志到 /var/jb/tmp/alsblocker.log，安装后读这个文件即可知道宿主与是否生效。
//
// 验收：原彩关 -> 傍晚室外不变黄；原彩开 -> 白点恒定不随光跳。
// 恢复：TrollFools 移除，或 SSH `mv /var/jb/usr/lib/TweakInject/ALSBlocker.dylib{,.disabled}` 后 reboot；
//       紧急 rescue：`touch /var/jb/tmp/alsblocker.disable && reboot`。

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <unistd.h>

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

// 文件 kill-switch：存在则完全不挂 hook
static BOOL ALSBlockerDisabled(void) {
    return access("/var/jb/tmp/alsblocker.disable", F_OK) == 0;
}

// CBColorModuleiOS 是 CoreBrightness 私有类，无公开头文件；Logos 运行时按名查找，找不到则静默失效。
@interface CBColorModuleiOS : NSObject
- (id)init;
- (id)start;
@end

// 钉死"丢弃 ALS 采样"开关；ivar 缺失则跳过，绝不写坏地址。
static inline void ALSBlocker_DropALS(id self) {
    if (!self) return;
    Ivar iv = class_getInstanceVariable(object_getClass(self), "_dropALSColorSamples");
    if (!iv) {
        ALSLog(@"_dropALSColorSamples ivar NOT found -> skip (no crash)");
        return;
    }
    MSHookIvar<BOOL>(self, "_dropALSColorSamples") = YES;
    ALSLog(@"_dropALSColorSamples = YES applied");
}

%ctor {
    if (ALSBlockerDisabled()) {
        ALSLog(@"DISABLED via kill-switch file, not hooking");
        return;
    }
    ALSLog(@"loaded");
}

%hook CBColorModuleiOS

- (id)init {
    id s = %orig;
    ALSLog(@"CBColorModuleiOS init called");
    ALSBlocker_DropALS(s);
    return s;
}

- (id)start {
    id r = %orig;
    ALSLog(@"CBColorModuleiOS start called");
    ALSBlocker_DropALS(self);
    return r;
}

%end
