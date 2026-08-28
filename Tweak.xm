// ALSBlocker — 强制让 True Tone 丢弃环境光（ALS）颜色采样，屏幕白点恒定中性、不再随光变黄。
//
// 背景：
//   老板的 iPhone 14 Pro Max（iOS 16.6, rootless）傍晚室外会整屏变黄，即使「原彩显示」在
//   设置里显示为关。实测 True Tone 的光线读取在 backboardd 内（backboardd 是系统唯一链接
//   CoreBrightness.framework 的守护进程，launchctl 里无独立 corebrightnessd）。
//
// 路线A 机制（class-dump 实锤）：
//   CoreBrightness 内部类 CBColorModuleiOS（True Tone 服务端）自带 ivar
//   `_dropALSColorSamples`（BOOL，偏移 +0x120）。当它为 YES 时，苹果自己的代码会跳过
//   ALS 颜色采样 -> 白点计算拿不到环境色温 -> 白点恒定不更新 -> 屏幕不再随光变黄。
//   这是苹果自己留的开关，比外挂拦截 IOKit 更稳、更干净。
//
// 注入目标：com.apple.backboardd（CoreBrightness 服务端宿主）。
//
// 验收（重启/杀 backboardd 加载后）：
//   - 原彩关 -> 傍晚室外不变黄（解决初衷）；
//   - 原彩开 -> 无 ALS 输入，白点恒定不随光跳，一般也不黄。
//
// 恢复：TrollFools 移除，或 SSH `mv /var/jb/usr/lib/TweakInject/ALSBlocker.dylib{,.disabled}` 后 reboot。

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <os/log.h>

// 前向声明：CBColorModuleiOS 是 CoreBrightness 私有类，无公开头文件。
// Logos 运行时按名字查找该类，找不到则本 %hook 静默失效，不会崩。
@interface CBColorModuleiOS : NSObject
- (id)init;
- (id)start;
@end

static os_log_t ALSBlockerLog(void) {
    static os_log_t log = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.alsblocker", "tweak");
    });
    return log;
}

// 把 True Tone 的 ALS 颜色采样丢弃开关钉死为 YES。
static inline void ALSBlocker_DropALS(id self) {
    if (!self) return;
    MSHookIvar<BOOL>(self, "_dropALSColorSamples") = YES;
    os_log(ALSBlockerLog(), "ALSBlocker: _dropALSColorSamples = YES");
}

%hook CBColorModuleiOS

- (id)init {
    id s = %orig;
    ALSBlocker_DropALS(s);
    return s;
}

- (id)start {
    id r = %orig;
    ALSBlocker_DropALS(self);
    return r;
}

%end
