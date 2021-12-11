// dear imgui: Platform Backend for OSX / Cocoa
// This needs to be used along with a Renderer (e.g. OpenGL2, OpenGL3, Vulkan, Metal..)
// [ALPHA] Early backend, not well tested. If you want a portable application, prefer using the GLFW or SDL platform Backends on Mac.

// Implemented features:
//  [X] Platform: Mouse cursor shape and visibility. Disable with 'io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange'.
//  [X] Platform: OSX clipboard is supported within core Dear ImGui (no specific code in this backend).
// Issues:
//  [ ] Platform: Keys are all generally very broken. Best using [event keycode] and not [event characters]..

// You can use unmodified imgui_impl_* files in your project. See examples/ folder for examples of using this.
// Prefer including the entire imgui/ repository into your project (either as a copy or as a submodule), and only build the backends you need.
// If you are new to Dear ImGui, read documentation from the docs/ folder + read the top of imgui.cpp.
// Read online: https://github.com/ocornut/imgui/tree/master/docs

#include "imgui.h"
#include "imgui_impl_osx.h"
#import <Cocoa/Cocoa.h>
#include <mach/mach_time.h>
#include <wctype.h>

// CHANGELOG
// (minor and older changes stripped away, please see git history for details)
//  2021-09-21: Use mach_absolute_time as CFAbsoluteTimeGetCurrent can jump backwards.
//  2021-08-17: Calling io.AddFocusEvent() on NSApplicationDidBecomeActiveNotification/NSApplicationDidResignActiveNotification events.
//  2021-06-23: Inputs: Added a fix for shortcuts using CTRL key instead of CMD key.
//  2021-04-19: Inputs: Added a fix for keys remaining stuck in pressed state when CMD-tabbing into different application.
//  2021-01-27: Inputs: Added a fix for mouse position not being reported when mouse buttons other than left one are down.
//  2020-10-28: Inputs: Added a fix for handling keypad-enter key.
//  2020-05-25: Inputs: Added a fix for missing trackpad clicks when done with "soft tap".
//  2019-12-05: Inputs: Added support for ImGuiMouseCursor_NotAllowed mouse cursor.
//  2019-10-11: Inputs:  Fix using Backspace key.
//  2019-07-21: Re-added clipboard handlers as they are not enabled by default in core imgui.cpp (reverted 2019-05-18 change).
//  2019-05-28: Inputs: Added mouse cursor shape and visibility support.
//  2019-05-18: Misc: Removed clipboard handlers as they are now supported by core imgui.cpp.
//  2019-05-11: Inputs: Don't filter character values before calling AddInputCharacter() apart from 0xF700..0xFFFF range.
//  2018-11-30: Misc: Setting up io.BackendPlatformName so it can be displayed in the About Window.
//  2018-07-07: Initial version.

@class ImFocusObserver;

// Data
static double           g_HostClockPeriod = 0.0;
static double           g_Time = 0.0;
static NSCursor*        g_MouseCursors[ImGuiMouseCursor_COUNT] = {};
static bool             g_MouseCursorHidden = false;
static bool             g_MouseJustPressed[ImGuiMouseButton_COUNT] = {};
static bool             g_MouseDown[ImGuiMouseButton_COUNT] = {};
static ImGuiKeyModFlags g_KeyModifiers = ImGuiKeyModFlags_None;
static ImFocusObserver* g_FocusObserver = NULL;

// Undocumented methods for creating cursors.
@interface NSCursor()
+ (id)_windowResizeNorthWestSouthEastCursor;
+ (id)_windowResizeNorthEastSouthWestCursor;
+ (id)_windowResizeNorthSouthCursor;
+ (id)_windowResizeEastWestCursor;
@end

static void InitHostClockPeriod()
{
    struct mach_timebase_info info;
    mach_timebase_info(&info);
    g_HostClockPeriod = 1e-9 * ((double)info.denom / (double)info.numer); // Period is the reciprocal of frequency.
}

static double GetMachAbsoluteTimeInSeconds()
{
    return (double)mach_absolute_time() * g_HostClockPeriod;
}

static void resetKeys()
{
    ImGuiIO& io = ImGui::GetIO();
    memset(io.KeysDown, 0, sizeof(io.KeysDown));
    io.KeyCtrl = io.KeyShift = io.KeyAlt = io.KeySuper = false;
}

@interface ImFocusObserver : NSObject

- (void)onApplicationBecomeActive:(NSNotification*)aNotification;
- (void)onApplicationBecomeInactive:(NSNotification*)aNotification;

@end

@implementation ImFocusObserver

- (void)onApplicationBecomeActive:(NSNotification*)aNotification
{
    ImGuiIO& io = ImGui::GetIO();
    io.AddFocusEvent(true);
}

- (void)onApplicationBecomeInactive:(NSNotification*)aNotification
{
    ImGuiIO& io = ImGui::GetIO();
    io.AddFocusEvent(false);

    // Unfocused applications do not receive input events, therefore we must manually
    // release any pressed keys when application loses focus, otherwise they would remain
    // stuck in a pressed state. https://github.com/ocornut/imgui/issues/3832
    resetKeys();
}

@end

// Functions
bool ImGui_ImplOSX_Init()
{
    ImGuiIO& io = ImGui::GetIO();

    // Setup backend capabilities flags
    io.BackendFlags |= ImGuiBackendFlags_HasMouseCursors;           // We can honor GetMouseCursor() values (optional)
    //io.BackendFlags |= ImGuiBackendFlags_HasSetMousePos;          // We can honor io.WantSetMousePos requests (optional, rarely used)
    //io.BackendFlags |= ImGuiBackendFlags_PlatformHasViewports;    // We can create multi-viewports on the Platform side (optional)
    //io.BackendFlags |= ImGuiBackendFlags_HasMouseHoveredViewport; // We can set io.MouseHoveredViewport correctly (optional, not easy)
    io.BackendPlatformName = "imgui_impl_osx";

    // Keyboard mapping. Dear ImGui will use those indices to peek into the io.KeyDown[] array.
    // Constnats for Virtual Keys can be found in header:
    // /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/Events.h
#ifdef IMGUI_HAS_EXTRA_KEYS
    io.KeyMap[ImGuiKey_A]              = 0x00; /* kVK_ANSI_A */
    io.KeyMap[ImGuiKey_S]              = 0x01; /* kVK_ANSI_S */
    io.KeyMap[ImGuiKey_D]              = 0x02; /* kVK_ANSI_D */
    io.KeyMap[ImGuiKey_F]              = 0x03; /* kVK_ANSI_F */
    io.KeyMap[ImGuiKey_H]              = 0x04; /* kVK_ANSI_H */
    io.KeyMap[ImGuiKey_G]              = 0x05; /* kVK_ANSI_G */
    io.KeyMap[ImGuiKey_Z]              = 0x06; /* kVK_ANSI_Z */
    io.KeyMap[ImGuiKey_X]              = 0x07; /* kVK_ANSI_X */
    io.KeyMap[ImGuiKey_C]              = 0x08; /* kVK_ANSI_C */
    io.KeyMap[ImGuiKey_V]              = 0x09; /* kVK_ANSI_V */
    io.KeyMap[ImGuiKey_B]              = 0x0B; /* kVK_ANSI_B */
    io.KeyMap[ImGuiKey_Q]              = 0x0C; /* kVK_ANSI_Q */
    io.KeyMap[ImGuiKey_W]              = 0x0D; /* kVK_ANSI_W */
    io.KeyMap[ImGuiKey_E]              = 0x0E; /* kVK_ANSI_E */
    io.KeyMap[ImGuiKey_R]              = 0x0F; /* kVK_ANSI_R */
    io.KeyMap[ImGuiKey_Y]              = 0x10; /* kVK_ANSI_Y */
    io.KeyMap[ImGuiKey_T]              = 0x11; /* kVK_ANSI_T */
    io.KeyMap[ImGuiKey_1]              = 0x12; /* kVK_ANSI_1 */
    io.KeyMap[ImGuiKey_2]              = 0x13; /* kVK_ANSI_2 */
    io.KeyMap[ImGuiKey_3]              = 0x14; /* kVK_ANSI_3 */
    io.KeyMap[ImGuiKey_4]              = 0x15; /* kVK_ANSI_4 */
    io.KeyMap[ImGuiKey_6]              = 0x16; /* kVK_ANSI_6 */
    io.KeyMap[ImGuiKey_5]              = 0x17; /* kVK_ANSI_5 */
    io.KeyMap[ImGuiKey_Equal]          = 0x18; /* kVK_ANSI_Equal */
    io.KeyMap[ImGuiKey_9]              = 0x19; /* kVK_ANSI_9 */
    io.KeyMap[ImGuiKey_7]              = 0x1A; /* kVK_ANSI_7 */
    io.KeyMap[ImGuiKey_Minus]          = 0x1B; /* kVK_ANSI_Minus */
    io.KeyMap[ImGuiKey_8]              = 0x1C; /* kVK_ANSI_8 */
    io.KeyMap[ImGuiKey_0]              = 0x1D; /* kVK_ANSI_0 */
    io.KeyMap[ImGuiKey_RightBracket]   = 0x1E; /* kVK_ANSI_RightBracket */
    io.KeyMap[ImGuiKey_O]              = 0x1F; /* kVK_ANSI_O */
    io.KeyMap[ImGuiKey_U]              = 0x20; /* kVK_ANSI_U */
    io.KeyMap[ImGuiKey_LeftBracket]    = 0x21; /* kVK_ANSI_LeftBracket */
    io.KeyMap[ImGuiKey_I]              = 0x22; /* kVK_ANSI_I */
    io.KeyMap[ImGuiKey_P]              = 0x23; /* kVK_ANSI_P */
    io.KeyMap[ImGuiKey_L]              = 0x25; /* kVK_ANSI_L */
    io.KeyMap[ImGuiKey_J]              = 0x26; /* kVK_ANSI_J */
    io.KeyMap[ImGuiKey_Apostrophe]     = 0x27; /* kVK_ANSI_Quote */
    io.KeyMap[ImGuiKey_K]              = 0x28; /* kVK_ANSI_K */
    io.KeyMap[ImGuiKey_Semicolon]      = 0x29; /* kVK_ANSI_Semicolon */
    io.KeyMap[ImGuiKey_Backslash]      = 0x2A; /* kVK_ANSI_Backslash */
    io.KeyMap[ImGuiKey_Comma]          = 0x2B; /* kVK_ANSI_Comma */
    io.KeyMap[ImGuiKey_Slash]          = 0x2C; /* kVK_ANSI_Slash */
    io.KeyMap[ImGuiKey_N]              = 0x2D; /* kVK_ANSI_N */
    io.KeyMap[ImGuiKey_M]              = 0x2E; /* kVK_ANSI_M */
    io.KeyMap[ImGuiKey_Period]         = 0x2F; /* kVK_ANSI_Period */
    io.KeyMap[ImGuiKey_GraveAccent]    = 0x32; /* kVK_ANSI_Grave */
    io.KeyMap[ImGuiKey_KeyPadDecimal]  = 0x41; /* kVK_ANSI_KeypadDecimal */
    io.KeyMap[ImGuiKey_KeyPadMultiply] = 0x43; /* kVK_ANSI_KeypadMultiply */
    io.KeyMap[ImGuiKey_KeyPadAdd]      = 0x45; /* kVK_ANSI_KeypadPlus */
    io.KeyMap[ImGuiKey_NumLock]        = 0x47; /* kVK_ANSI_KeypadClear */
    io.KeyMap[ImGuiKey_KeyPadDivide]   = 0x4B; /* kVK_ANSI_KeypadDivide */
    io.KeyMap[ImGuiKey_KeyPadEnter]    = 0x4C; /* kVK_ANSI_KeypadEnter */
    io.KeyMap[ImGuiKey_KeyPadSubtract] = 0x4E; /* kVK_ANSI_KeypadMinus */
    io.KeyMap[ImGuiKey_KeyPadEqual]    = 0x51; /* kVK_ANSI_KeypadEquals */
    io.KeyMap[ImGuiKey_KeyPad0]        = 0x52; /* kVK_ANSI_Keypad0 */
    io.KeyMap[ImGuiKey_KeyPad1]        = 0x53; /* kVK_ANSI_Keypad1 */
    io.KeyMap[ImGuiKey_KeyPad2]        = 0x54; /* kVK_ANSI_Keypad2 */
    io.KeyMap[ImGuiKey_KeyPad3]        = 0x55; /* kVK_ANSI_Keypad3 */
    io.KeyMap[ImGuiKey_KeyPad4]        = 0x56; /* kVK_ANSI_Keypad4 */
    io.KeyMap[ImGuiKey_KeyPad5]        = 0x57; /* kVK_ANSI_Keypad5 */
    io.KeyMap[ImGuiKey_KeyPad6]        = 0x58; /* kVK_ANSI_Keypad6 */
    io.KeyMap[ImGuiKey_KeyPad7]        = 0x59; /* kVK_ANSI_Keypad7 */
    io.KeyMap[ImGuiKey_KeyPad8]        = 0x5B; /* kVK_ANSI_Keypad8 */
    io.KeyMap[ImGuiKey_KeyPad9]        = 0x5C; /* kVK_ANSI_Keypad9 */
    io.KeyMap[ImGuiKey_Enter]          = 0x24; /* kVK_Return */
    io.KeyMap[ImGuiKey_Tab]            = 0x30; /* kVK_Tab */
    io.KeyMap[ImGuiKey_Space]          = 0x31; /* kVK_Space */
    io.KeyMap[ImGuiKey_Backspace]      = 0x33; /* kVK_Delete */
    io.KeyMap[ImGuiKey_Escape]         = 0x35; /* kVK_Escape */
    io.KeyMap[ImGuiKey_LeftSuper]      = 0x37; /* kVK_Command */
    io.KeyMap[ImGuiKey_LeftShift]      = 0x38; /* kVK_Shift */
    io.KeyMap[ImGuiKey_CapsLock]       = 0x39; /* kVK_CapsLock */
    io.KeyMap[ImGuiKey_LeftAlt]        = 0x3A; /* kVK_Option */
    io.KeyMap[ImGuiKey_LeftControl]    = 0x3B; /* kVK_Control */
    io.KeyMap[ImGuiKey_RightSuper]     = 0x36; /* kVK_RightCommand */
    io.KeyMap[ImGuiKey_RightShift]     = 0x3C; /* kVK_RightShift */
    io.KeyMap[ImGuiKey_RightAlt]       = 0x3D; /* kVK_RightOption */
    io.KeyMap[ImGuiKey_RightControl]   = 0x3E; /* kVK_RightControl */
//  io.KeyMap[ImGuiKey_]               = 0x3F; /* kVK_Function */
//  io.KeyMap[ImGuiKey_]               = 0x40; /* kVK_F17 */
//  io.KeyMap[ImGuiKey_]               = 0x48; /* kVK_VolumeUp */
//  io.KeyMap[ImGuiKey_]               = 0x49; /* kVK_VolumeDown */
//  io.KeyMap[ImGuiKey_]               = 0x4A; /* kVK_Mute */
//  io.KeyMap[ImGuiKey_]               = 0x4F; /* kVK_F18 */
//  io.KeyMap[ImGuiKey_]               = 0x50; /* kVK_F19 */
//  io.KeyMap[ImGuiKey_]               = 0x5A; /* kVK_F20 */
    io.KeyMap[ImGuiKey_F5]             = 0x60; /* kVK_F5 */
    io.KeyMap[ImGuiKey_F6]             = 0x61; /* kVK_F6 */
    io.KeyMap[ImGuiKey_F7]             = 0x62; /* kVK_F7 */
    io.KeyMap[ImGuiKey_F3]             = 0x63; /* kVK_F3 */
    io.KeyMap[ImGuiKey_F8]             = 0x64; /* kVK_F8 */
    io.KeyMap[ImGuiKey_F9]             = 0x65; /* kVK_F9 */
    io.KeyMap[ImGuiKey_F11]            = 0x67; /* kVK_F11 */
    io.KeyMap[ImGuiKey_PrintScreen]    = 0x69; /* kVK_F13 */
//  io.KeyMap[ImGuiKey_]               = 0x6A; /* kVK_F16 */
//  io.KeyMap[ImGuiKey_]               = 0x6B; /* kVK_F14 */
    io.KeyMap[ImGuiKey_F10]            = 0x6D; /* kVK_F10 */
    io.KeyMap[ImGuiKey_Menu]           = 0x6E;
    io.KeyMap[ImGuiKey_F12]            = 0x6F; /* kVK_F12 */
//  io.KeyMap[ImGuiKey_]               = 0x71; /* kVK_F15 */
    io.KeyMap[ImGuiKey_Insert]         = 0x72; /* kVK_Help */
    io.KeyMap[ImGuiKey_Home]           = 0x73; /* kVK_Home */
    io.KeyMap[ImGuiKey_PageUp]         = 0x74; /* kVK_PageUp */
    io.KeyMap[ImGuiKey_Delete]         = 0x75; /* kVK_ForwardDelete */
    io.KeyMap[ImGuiKey_F4]             = 0x76; /* kVK_F4 */
    io.KeyMap[ImGuiKey_End]            = 0x77; /* kVK_End */
    io.KeyMap[ImGuiKey_F2]             = 0x78; /* kVK_F2 */
    io.KeyMap[ImGuiKey_PageDown]       = 0x79; /* kVK_PageDown */
    io.KeyMap[ImGuiKey_F1]             = 0x7A; /* kVK_F1 */
    io.KeyMap[ImGuiKey_LeftArrow]      = 0x7B; /* kVK_LeftArrow */
    io.KeyMap[ImGuiKey_RightArrow]     = 0x7C; /* kVK_RightArrow */
    io.KeyMap[ImGuiKey_DownArrow]      = 0x7D; /* kVK_DownArrow */
    io.KeyMap[ImGuiKey_UpArrow]        = 0x7E; /* kVK_UpArrow */
#else
    io.KeyMap[ImGuiKey_A]              = 0x00; /* kVK_ANSI_A */
    io.KeyMap[ImGuiKey_Z]              = 0x06; /* kVK_ANSI_Z */
    io.KeyMap[ImGuiKey_X]              = 0x07; /* kVK_ANSI_X */
    io.KeyMap[ImGuiKey_C]              = 0x08; /* kVK_ANSI_C */
    io.KeyMap[ImGuiKey_V]              = 0x09; /* kVK_ANSI_V */
    io.KeyMap[ImGuiKey_Y]              = 0x10; /* kVK_ANSI_Y */
    io.KeyMap[ImGuiKey_KeyPadEnter]    = 0x4C; /* kVK_ANSI_KeypadEnter */
    io.KeyMap[ImGuiKey_Enter]          = 0x24; /* kVK_Return */
    io.KeyMap[ImGuiKey_Tab]            = 0x30; /* kVK_Tab */
    io.KeyMap[ImGuiKey_Space]          = 0x31; /* kVK_Space */
    io.KeyMap[ImGuiKey_Backspace]      = 0x33; /* kVK_Delete */
    io.KeyMap[ImGuiKey_Escape]         = 0x35; /* kVK_Escape */
    io.KeyMap[ImGuiKey_Insert]         = 0x72; /* kVK_Help */
    io.KeyMap[ImGuiKey_Home]           = 0x73; /* kVK_Home */
    io.KeyMap[ImGuiKey_PageUp]         = 0x74; /* kVK_PageUp */
    io.KeyMap[ImGuiKey_Delete]         = 0x75; /* kVK_ForwardDelete */
    io.KeyMap[ImGuiKey_End]            = 0x77; /* kVK_End */
    io.KeyMap[ImGuiKey_PageDown]       = 0x79; /* kVK_PageDown */
    io.KeyMap[ImGuiKey_LeftArrow]      = 0x7B; /* kVK_LeftArrow */
    io.KeyMap[ImGuiKey_RightArrow]     = 0x7C; /* kVK_RightArrow */
    io.KeyMap[ImGuiKey_DownArrow]      = 0x7D; /* kVK_DownArrow */
    io.KeyMap[ImGuiKey_UpArrow]        = 0x7E; /* kVK_UpArrow */
#endif // IMGUI_HAS_EXTRA_KEYS

    // Load cursors. Some of them are undocumented.
    g_MouseCursorHidden = false;
    g_MouseCursors[ImGuiMouseCursor_Arrow] = [NSCursor arrowCursor];
    g_MouseCursors[ImGuiMouseCursor_TextInput] = [NSCursor IBeamCursor];
    g_MouseCursors[ImGuiMouseCursor_ResizeAll] = [NSCursor closedHandCursor];
    g_MouseCursors[ImGuiMouseCursor_Hand] = [NSCursor pointingHandCursor];
    g_MouseCursors[ImGuiMouseCursor_NotAllowed] = [NSCursor operationNotAllowedCursor];
    g_MouseCursors[ImGuiMouseCursor_ResizeNS] = [NSCursor respondsToSelector:@selector(_windowResizeNorthSouthCursor)] ? [NSCursor _windowResizeNorthSouthCursor] : [NSCursor resizeUpDownCursor];
    g_MouseCursors[ImGuiMouseCursor_ResizeEW] = [NSCursor respondsToSelector:@selector(_windowResizeEastWestCursor)] ? [NSCursor _windowResizeEastWestCursor] : [NSCursor resizeLeftRightCursor];
    g_MouseCursors[ImGuiMouseCursor_ResizeNESW] = [NSCursor respondsToSelector:@selector(_windowResizeNorthEastSouthWestCursor)] ? [NSCursor _windowResizeNorthEastSouthWestCursor] : [NSCursor closedHandCursor];
    g_MouseCursors[ImGuiMouseCursor_ResizeNWSE] = [NSCursor respondsToSelector:@selector(_windowResizeNorthWestSouthEastCursor)] ? [NSCursor _windowResizeNorthWestSouthEastCursor] : [NSCursor closedHandCursor];

    // Note that imgui.cpp also include default OSX clipboard handlers which can be enabled
    // by adding '#define IMGUI_ENABLE_OSX_DEFAULT_CLIPBOARD_FUNCTIONS' in imconfig.h and adding '-framework ApplicationServices' to your linker command-line.
    // Since we are already in ObjC land here, it is easy for us to add a clipboard handler using the NSPasteboard api.
    io.SetClipboardTextFn = [](void*, const char* str) -> void
    {
        NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard declareTypes:[NSArray arrayWithObject:NSPasteboardTypeString] owner:nil];
        [pasteboard setString:[NSString stringWithUTF8String:str] forType:NSPasteboardTypeString];
    };

    io.GetClipboardTextFn = [](void*) -> const char*
    {
        NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
        NSString* available = [pasteboard availableTypeFromArray: [NSArray arrayWithObject:NSPasteboardTypeString]];
        if (![available isEqualToString:NSPasteboardTypeString])
            return NULL;

        NSString* string = [pasteboard stringForType:NSPasteboardTypeString];
        if (string == nil)
            return NULL;

        const char* string_c = (const char*)[string UTF8String];
        size_t string_len = strlen(string_c);
        static ImVector<char> s_clipboard;
        s_clipboard.resize((int)string_len + 1);
        strcpy(s_clipboard.Data, string_c);
        return s_clipboard.Data;
    };

    g_FocusObserver = [[ImFocusObserver alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:g_FocusObserver
                                             selector:@selector(onApplicationBecomeActive:)
                                                 name:NSApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:g_FocusObserver
                                             selector:@selector(onApplicationBecomeInactive:)
                                                 name:NSApplicationDidResignActiveNotification
                                               object:nil];

    return true;
}

void ImGui_ImplOSX_Shutdown()
{
    g_FocusObserver = NULL;
}

static void ImGui_ImplOSX_UpdateMouseCursorAndButtons()
{
    // Update buttons
    ImGuiIO& io = ImGui::GetIO();
    for (int i = 0; i < IM_ARRAYSIZE(io.MouseDown); i++)
    {
        // If a mouse press event came, always pass it as "mouse held this frame", so we don't miss click-release events that are shorter than 1 frame.
        io.MouseDown[i] = g_MouseJustPressed[i] || g_MouseDown[i];
        g_MouseJustPressed[i] = false;
    }

    if (io.ConfigFlags & ImGuiConfigFlags_NoMouseCursorChange)
        return;

    ImGuiMouseCursor imgui_cursor = ImGui::GetMouseCursor();
    if (io.MouseDrawCursor || imgui_cursor == ImGuiMouseCursor_None)
    {
        // Hide OS mouse cursor if imgui is drawing it or if it wants no cursor
        if (!g_MouseCursorHidden)
        {
            g_MouseCursorHidden = true;
            [NSCursor hide];
        }
    }
    else
    {
        // Show OS mouse cursor
        [g_MouseCursors[g_MouseCursors[imgui_cursor] ? imgui_cursor : ImGuiMouseCursor_Arrow] set];
        if (g_MouseCursorHidden)
        {
            g_MouseCursorHidden = false;
            [NSCursor unhide];
        }
    }
}

static void ImGui_ImplOSX_UpdateKeyModifiers()
{
    ImGuiIO& io = ImGui::GetIO();
    io.KeyCtrl  = (g_KeyModifiers & ImGuiKeyModFlags_Ctrl)  != 0;
    io.KeyShift = (g_KeyModifiers & ImGuiKeyModFlags_Shift) != 0;
    io.KeyAlt   = (g_KeyModifiers & ImGuiKeyModFlags_Alt)   != 0;
    io.KeySuper = (g_KeyModifiers & ImGuiKeyModFlags_Super) != 0;
}

void ImGui_ImplOSX_NewFrame(NSView* view)
{
    // Setup display size
    ImGuiIO& io = ImGui::GetIO();
    if (view)
    {
        const float dpi = (float)[view.window backingScaleFactor];
        io.DisplaySize = ImVec2((float)view.bounds.size.width, (float)view.bounds.size.height);
        io.DisplayFramebufferScale = ImVec2(dpi, dpi);
    }

    // Setup time step
    if (g_Time == 0.0)
    {
        InitHostClockPeriod();
        g_Time = GetMachAbsoluteTimeInSeconds();
    }
    double current_time = GetMachAbsoluteTimeInSeconds();
    io.DeltaTime = (float)(current_time - g_Time);
    g_Time = current_time;

    ImGui_ImplOSX_UpdateKeyModifiers();
    ImGui_ImplOSX_UpdateMouseCursorAndButtons();
}

bool ImGui_ImplOSX_HandleEvent(NSEvent* event, NSView* view)
{
    ImGuiIO& io = ImGui::GetIO();

    if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown || event.type == NSEventTypeOtherMouseDown)
    {
        int button = (int)[event buttonNumber];
        if (button >= 0 && button < IM_ARRAYSIZE(g_MouseDown))
            g_MouseDown[button] = g_MouseJustPressed[button] = true;
        return io.WantCaptureMouse;
    }

    if (event.type == NSEventTypeLeftMouseUp || event.type == NSEventTypeRightMouseUp || event.type == NSEventTypeOtherMouseUp)
    {
        int button = (int)[event buttonNumber];
        if (button >= 0 && button < IM_ARRAYSIZE(g_MouseDown))
            g_MouseDown[button] = false;
        return io.WantCaptureMouse;
    }

    if (event.type == NSEventTypeMouseMoved || event.type == NSEventTypeLeftMouseDragged || event.type == NSEventTypeRightMouseDragged || event.type == NSEventTypeOtherMouseDragged)
    {
        NSPoint mousePoint = event.locationInWindow;
        mousePoint = [view convertPoint:mousePoint fromView:nil];
        mousePoint = NSMakePoint(mousePoint.x, view.bounds.size.height - mousePoint.y);
        io.MousePos = ImVec2((float)mousePoint.x, (float)mousePoint.y);
    }

    if (event.type == NSEventTypeScrollWheel)
    {
        double wheel_dx = 0.0;
        double wheel_dy = 0.0;

        #if MAC_OS_X_VERSION_MAX_ALLOWED >= 1070
        if (floor(NSAppKitVersionNumber) > NSAppKitVersionNumber10_6)
        {
            wheel_dx = [event scrollingDeltaX];
            wheel_dy = [event scrollingDeltaY];
            if ([event hasPreciseScrollingDeltas])
            {
                wheel_dx *= 0.1;
                wheel_dy *= 0.1;
            }
        }
        else
        #endif // MAC_OS_X_VERSION_MAX_ALLOWED
        {
            wheel_dx = [event deltaX];
            wheel_dy = [event deltaY];
        }

        if (fabs(wheel_dx) > 0.0)
            io.MouseWheelH += (float)wheel_dx * 0.1f;
        if (fabs(wheel_dy) > 0.0)
            io.MouseWheel += (float)wheel_dy * 0.1f;
        return io.WantCaptureMouse;
    }

    if (event.type == NSEventTypeKeyDown)
    {
        if ([event isARepeat])
            return io.WantCaptureKeyboard;

        unsigned short key_code = [event keyCode];
        if (key_code < 256)
            io.KeysDown[key_code] = true;

        // Text should be interpreted via interpretKeyEvents: in NSView, which
        // in consequence calls insertText:. We however have only NSEvents
        // to play with.
        // Burden of interpretation is on us, so we decided to pass trough
        // only printable characters.
        if (const unsigned int* text = (const unsigned int*)[[event characters] cStringUsingEncoding:NSUTF32StringEncoding])
        {
            while (unsigned int c = *text++)
            {
                if (iswprint(c))
                    io.AddInputCharacter(c);
            }
        }

        return io.WantCaptureKeyboard;
    }

    if (event.type == NSEventTypeKeyUp)
    {
        unsigned short key_code = [event keyCode];
        if (key_code < 256)
            io.KeysDown[key_code] = false;

        return io.WantCaptureKeyboard;
    }

    if (event.type == NSEventTypeFlagsChanged)
    {
        unsigned short key_code = [event keyCode];
        unsigned int flags = [event modifierFlags] & NSEventModifierFlagDeviceIndependentFlagsMask;

        ImGuiKeyModFlags imgui_flags = ImGuiKeyModFlags_None;
        if (flags & NSEventModifierFlagShift)
            imgui_flags |= ImGuiKeyModFlags_Shift;
        if (flags & NSEventModifierFlagControl)
            imgui_flags |= ImGuiKeyModFlags_Ctrl;
        if (flags & NSEventModifierFlagOption)
            imgui_flags |= ImGuiKeyModFlags_Alt;
        if (flags & NSEventModifierFlagCommand)
            imgui_flags |= ImGuiKeyModFlags_Super;

        if (g_KeyModifiers != imgui_flags)
        {
            g_KeyModifiers = imgui_flags;
            ImGui_ImplOSX_UpdateKeyModifiers();
        }

#ifdef IMGUI_HAS_EXTRA_KEYS
        if (key_code < 256)
        {
            ImGuiKey key = io.KeyMap[key_code];

            // macOS does not generate down/up event for modifiers. We're trying
            // to use hardware dependent masks to extract that information.
            // 'imgui_mask' is left as a fallback.
            NSEventModifierFlags mask = 0;
            ImGuiKeyModFlags imgui_mask = ImGuiKeyModFlags_None;
            switch ((int)key)
            {
                case ImGuiKey_LeftControl:  mask = 0x0001; imgui_mask = ImGuiKeyModFlags_Ctrl; break;
                case ImGuiKey_RightControl: mask = 0x2000; imgui_mask = ImGuiKeyModFlags_Ctrl; break;
                case ImGuiKey_LeftShift:    mask = 0x0002; imgui_mask = ImGuiKeyModFlags_Shift; break;
                case ImGuiKey_RightShift:   mask = 0x0004; imgui_mask = ImGuiKeyModFlags_Shift; break;
                case ImGuiKey_LeftSuper:    mask = 0x0008; imgui_mask = ImGuiKeyModFlags_Super; break;
                case ImGuiKey_RightSuper:   mask = 0x0010; imgui_mask = ImGuiKeyModFlags_Super; break;
                case ImGuiKey_LeftAlt:      mask = 0x0020; imgui_mask = ImGuiKeyModFlags_Alt; break;
                case ImGuiKey_RightAlt:     mask = 0x0040; imgui_mask = ImGuiKeyModFlags_Alt; break;
            }

            if (mask)
            {
                NSEventModifierFlags modifier_flags = [event modifierFlags];
                if (modifier_flags & mask)
                    io.KeysDown[key] = true;
                else
                    io.KeysDown[key] = false;
            }
            else if (imgui_mask)
            {
                if (imgui_flags & imgui_mask)
                    io.KeysDown[key] = true;
                else
                    io.KeysDown[key] = false;
            }
        }
#endif // IMGUI_HAS_EXTRA_KEYS

        return io.WantCaptureKeyboard;
    }

    return false;
}
