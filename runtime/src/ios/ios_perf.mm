// Performance overlay: frame rate, frame time, GPU time, memory and the device's thermal state in the
// top left corner, updated twice a second. Unlike Apple's Metal HUD it needs no Developer Mode and
// works inside host apps such as LiveContainer. Toggled in the touch controls' ≡ menu, remembered.
#import <UIKit/UIKit.h>
#include <mach/mach.h>

#include <algorithm>

#include "ios_shell.h"
#include "metal.h"

namespace {
UIView* g_box = nil;  // the dark rounded box; the label sits inside it with a margin
UILabel* g_label = nil;
NSTimer* g_timer = nil;
gfx::PerfSample g_last;
CFTimeInterval g_lastTime = 0;

double footprint_mb() {
    task_vm_info_data_t info;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) return -1;
    return info.phys_footprint / (1024.0 * 1024.0);
}

NSString* thermal() {
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal: return @"normal";
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return @"?";
}

void tick() {
    gfx::PerfSample s = gfx::perf_sample();
    CFTimeInterval now = CACurrentMediaTime();
    double dt = now - g_lastTime;
    if (g_lastTime > 0 && dt > 0) {
        uint64_t frames = s.frames - g_last.frames;
        double fps = frames / dt;
        double frameMs = frames ? dt * 1000.0 / frames : 0;
        double gpuMs = frames ? (s.gpu_ns - g_last.gpu_ns) / 1e6 / frames : 0;
        g_label.text = [NSString stringWithFormat:@"FPS %.1f\nFrame %.1f ms  max %.1f\nGPU %.1f ms\nMemory %.0f MB\nThermal %@",
                                                  fps, frameMs, s.max_gap_ms, gpuMs, footprint_mb(), thermal()];
        CGSize sz = [g_label sizeThatFits:CGSizeMake(1000, 1000)];
        g_label.frame = CGRectMake(6, 4, std::ceil(sz.width), std::ceil(sz.height));
        CGRect f = g_box.frame;
        f.size = CGSizeMake(std::ceil(sz.width) + 12, std::ceil(sz.height) + 8);
        g_box.frame = f;
    }
    g_last = s;
    g_lastTime = now;
}
}  // namespace

namespace ios {
bool perf_overlay() { return [NSUserDefaults.standardUserDefaults boolForKey:@"perfOverlay"]; }

// main thread; `parent`: the root view (the overlay sits above the game, below the touch controls)
void install_perf_overlay(UIView* parent, UIView* below) {
    if (!g_box) {
        g_box = [UIView new];
        g_box.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        g_box.layer.cornerRadius = 5;
        g_box.userInteractionEnabled = NO;
        g_label = [UILabel new];
        g_label.numberOfLines = 0;
        g_label.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        g_label.textColor = UIColor.whiteColor;
        g_label.text = @"FPS …";
        [g_box addSubview:g_label];
        CGSize sz = [g_label sizeThatFits:CGSizeMake(1000, 1000)];
        g_label.frame = CGRectMake(6, 4, sz.width, sz.height);
        g_box.frame = CGRectMake(0, 0, sz.width + 12, sz.height + 8);
    }
    if (g_box.superview != parent) [parent insertSubview:g_box belowSubview:below];
    UIEdgeInsets safe = parent.safeAreaInsets;
    CGRect f = g_box.frame;
    f.origin = CGPointMake(std::max<CGFloat>(safe.left, 8), std::max<CGFloat>(safe.top, 8));
    g_box.frame = f;
    bool on = perf_overlay();
    g_box.hidden = !on;
    if (on && !g_timer) {
        g_lastTime = 0;
        tick();
        g_timer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer*) { tick(); }];
        [NSRunLoop.mainRunLoop addTimer:g_timer forMode:NSRunLoopCommonModes];
    } else if (!on && g_timer) {
        [g_timer invalidate];
        g_timer = nil;
    }
}

void set_perf_overlay(bool on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"perfOverlay"];
    if (g_box.superview) install_perf_overlay(g_box.superview, root_view_controller().view.subviews.lastObject);
}
}  // namespace ios
