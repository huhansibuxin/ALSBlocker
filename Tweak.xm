// ALSBlocker — 禁用环境光传感器（ALS），让 True Tone 读不到光、不再随光暖屏。
//
// 背景：
//   老板的 iPhone 14 Pro Max（iOS 16.6, rootless）傍晚室外会整屏变黄，即使「原彩显示」
//   在设置里显示为关。实测：True Tone 的光线读取在 backboardd 内（backboardd 是系统唯一
//   链接 CoreBrightness.framework 的守护进程，launchctl 里无 corebrightnessd）。
//   环境光在系统里是一条 HID 事件流：任何消费者（CoreBrightness/True Tone）都通过
//   IOHIDEventSystemClient + SetMatching(PrimaryUsagePage=0xff00, PrimaryUsage=4) 去匹配
//   并订阅 ALS（参照开源 tweak LightsOut 的 iokit.c）。
//
// 机制：
//   hook backboardd 里的 IOHIDEventSystemClientSetMatching。当发现匹配参数是 ALS 时，
//   替换为空字典 —— 该 client 永远匹配不到 ALS 服务 -> 收不到环境光事件 -> True Tone
//   无光可感 -> 白点恒为中性 -> 屏幕不再随光变黄。
//
// 安全性：
//   - 只拦截 ALS 匹配（usage page 0xff00 / usage 4），其它 HID 设备匹配原样放行；
//   - 对 client 粒度生效，不动 CoreBrightness 其它逻辑；
//   - 影响面：自动亮度（老板本来就关）+ True Tone，均为预期。
//
// 安装后：TrollFools 注入 / make install 会自动重启 backboardd。
//   若装完仍残留暖色（True Tone 可能缓存了旧白点），重启一次手机即可让 True Tone
//   在"无传感器"状态下重新求值 -> 中性白。
//   想恢复：TrollFools 里移除本插件，或 SSH `mv /var/jb/usr/lib/TweakInject/ALSBlocker.dylib{,.disabled}` 后 reboot。

#import <substrate.h>
#import <CoreFoundation/CoreFoundation.h>

// ---- IOKit HID 相关声明（IOKit 已通过 Makefile 链接）----
// 注意：.xm 是 ObjC++，C 函数声明必须包 extern "C"，
// 否则会被 C++ name mangling 成 C++ 符号，链接时找不到 IOKit.tbd 里的 C 符号
// （报错形如：found '_IOHIDEventSystemClientSetMatching' ... declaration possibly missing 'extern "C"'）
typedef CFTypeRef IOHIDEventSystemClientRef;
#ifdef __cplusplus
extern "C" {
#endif
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
#ifdef __cplusplus
}
#endif

// 判断某次 SetMatching 是否在请求"环境光传感器"
// 依据 LightsOut 源码：ALS 的 HID usage 是 PrimaryUsagePage = 0xff00, PrimaryUsage = 4。
static BOOL ALSBlocker_IsALSRequest(CFDictionaryRef matching) {
    if (!matching || CFGetTypeID(matching) != CFDictionaryGetTypeID()) {
        return NO;
    }
    // CFDictionaryGetValue 返回 const void*，ObjC++ 需显式强转（LightsOut 是纯 C 所以不需要）
    CFNumberRef pageNum  = (CFNumberRef)CFDictionaryGetValue(matching, CFSTR("PrimaryUsagePage"));
    CFNumberRef usageNum = (CFNumberRef)CFDictionaryGetValue(matching, CFSTR("PrimaryUsage"));
    if (!pageNum || !usageNum) {
        return NO;
    }
    int page  = 0;
    int usage = 0;
    CFNumberGetValue(pageNum,  kCFNumberSInt32Type, &page);
    CFNumberGetValue(usageNum, kCFNumberSInt32Type, &usage);
    return (page == 0xff00 && usage == 4);
}

%hookf(void, IOHIDEventSystemClientSetMatching, IOHIDEventSystemClientRef client, CFDictionaryRef matching) {
    if (ALSBlocker_IsALSRequest(matching)) {
        // 换成空匹配：让该 client 永远找不到 ALS 服务，等于拔掉光线传感器的"数据线"
        CFDictionaryRef empty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        if (empty) {
            %orig(client, empty);
            CFRelease(empty);
            return;
        }
    }
    // 非 ALS 的匹配（触摸、按键等 HID）原样放行
    %orig(client, matching);
}
