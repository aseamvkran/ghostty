//! Win32 API declarations for windowing, GDI, and OpenGL (WGL).
//! These supplement src/os/windows.zig which covers process/pipe/ConPTY.
const std = @import("std");

// Re-export common types from std
pub const BOOL = std.os.windows.BOOL;
pub const DWORD = std.os.windows.DWORD;
pub const HANDLE = std.os.windows.HANDLE;
pub const HINSTANCE = std.os.windows.HINSTANCE;
pub const WINAPI = std.builtin.CallingConvention.winapi;

// Opaque handle types
pub const HWND = *opaque {};
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HMODULE = *opaque {};

pub const ATOM = u16;
pub const UINT = u32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const LONG = i32;
pub const BYTE = u8;
pub const WORD = u16;
pub const INT = i32;

// Function pointer types
pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

// Window messages
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
pub const WM_IME_COMPOSITION: UINT = 0x010F;

// Window styles
pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_OVERLAPPEDWINDOW: DWORD = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

// Class styles
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_OWNDC: UINT = 0x0020;

// Show window constants
pub const SW_HIDE: INT = 0;
pub const SW_SHOWNORMAL: INT = 1;
pub const SW_MAXIMIZE: INT = 3;
pub const SW_MINIMIZE: INT = 6;
pub const SW_RESTORE: INT = 9;

// Defaults
pub const CW_USEDEFAULT: INT = @bitCast(@as(u32, 0x80000000));

// SetWindowLongPtr indices
pub const GWLP_USERDATA: INT = -21;
pub const GWL_STYLE: INT = -16;

// Pixel format descriptor flags
pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
pub const PFD_TYPE_RGBA: BYTE = 0;
pub const PFD_MAIN_PLANE: BYTE = 0;

// System cursor IDs
pub const IDC_ARROW: [*:0]const u16 = @ptrFromInt(32512);
pub const IDC_SIZENS: [*:0]const u16 = @ptrFromInt(32645);
pub const IDC_SIZEWE: [*:0]const u16 = @ptrFromInt(32644);

// WM_SETCURSOR hit-test codes (low word of lParam)
pub const HTCLIENT: u16 = 1;

// Structures
pub const POINT = extern struct {
    x: LONG = 0,
    y: LONG = 0,
};

pub const RECT = extern struct {
    left: LONG = 0,
    top: LONG = 0,
    right: LONG = 0,
    bottom: LONG = 0,
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: UINT = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: ?WNDPROC = null,
    cbClsExtra: INT = 0,
    cbWndExtra: INT = 0,
    hInstance: ?HMODULE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: ?[*:0]const u16 = null,
    hIconSm: ?HICON = null,
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]BYTE = std.mem.zeroes([32]BYTE),
};

pub const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: WORD = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: WORD = 0,
    dwFlags: DWORD = 0,
    iPixelType: BYTE = 0,
    cColorBits: BYTE = 0,
    cRedBits: BYTE = 0,
    cRedShift: BYTE = 0,
    cGreenBits: BYTE = 0,
    cGreenShift: BYTE = 0,
    cBlueBits: BYTE = 0,
    cBlueShift: BYTE = 0,
    cAlphaBits: BYTE = 0,
    cAlphaShift: BYTE = 0,
    cAccumBits: BYTE = 0,
    cAccumRedBits: BYTE = 0,
    cAccumGreenBits: BYTE = 0,
    cAccumBlueBits: BYTE = 0,
    cAccumAlphaBits: BYTE = 0,
    cDepthBits: BYTE = 0,
    cStencilBits: BYTE = 0,
    cAuxBuffers: BYTE = 0,
    iLayerType: BYTE = 0,
    bReserved: BYTE = 0,
    dwLayerMask: DWORD = 0,
    dwVisibleMask: DWORD = 0,
    dwDamageMask: DWORD = 0,
};

/// Encode `utf8` into `buf` as a null-terminated UTF-16 string.
///
/// Returns null if it does not fit or the input is invalid UTF-8. This
/// pre-check is mandatory: `std.unicode.utf8ToUtf16Le` does NOT bounds-check
/// its destination, so an oversized input writes past the end of `buf`.
pub fn utf16Z(buf: []u16, utf8: []const u8) ?[:0]const u16 {
    const need = std.unicode.calcUtf16LeLen(utf8) catch return null;
    if (need + 1 > buf.len) return null;
    const len = std.unicode.utf8ToUtf16Le(buf, utf8) catch return null;
    buf[len] = 0;
    return buf[0..len :0];
}

test utf16Z {
    const testing = std.testing;
    var buf: [8]u16 = undefined;

    // Fits, including the null terminator.
    try testing.expectEqualSlices(
        u16,
        std.unicode.utf8ToUtf16LeStringLiteral("hello"),
        utf16Z(&buf, "hello").?,
    );

    // Exactly fills the buffer with room for the terminator.
    try testing.expect(utf16Z(&buf, "1234567") != null);

    // One too long: must refuse rather than overflow `buf`.
    try testing.expect(utf16Z(&buf, "12345678") == null);

    // Surrogate pairs count as two UTF-16 units.
    try testing.expect(utf16Z(&buf, "𐐷𐐷𐐷𐐷") == null);

    // Invalid UTF-8 is refused.
    try testing.expect(utf16Z(&buf, "\xff") == null);
}

// User32 functions
pub extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(WINAPI) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: ?[*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: DWORD,
    X: INT,
    Y: INT,
    nWidth: INT,
    nHeight: INT,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HMODULE,
    lpParam: ?*anyopaque,
) callconv(WINAPI) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: INT) callconv(WINAPI) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn GetMessageW(
    lpMsg: *MSG,
    hWnd: ?HWND,
    wMsgFilterMin: UINT,
    wMsgFilterMax: UINT,
) callconv(WINAPI) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(WINAPI) BOOL;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: INT) callconv(WINAPI) void;
pub extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) BOOL;
pub extern "user32" fn LoadCursorW(hInstance: ?HMODULE, lpCursorName: [*:0]const u16) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(WINAPI) ?HDC;
pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: INT, dwNewLong: isize) callconv(WINAPI) isize;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: INT) callconv(WINAPI) isize;
pub extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(WINAPI) UINT;
pub extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: [*:0]const u16, lpCaption: [*:0]const u16, uType: UINT) callconv(WINAPI) INT;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetKeyState(nVirtKey: INT) callconv(WINAPI) i16;
pub extern "user32" fn MapVirtualKeyW(uCode: UINT, uMapType: UINT) callconv(WINAPI) UINT;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(WINAPI) BOOL;
pub extern "user32" fn ClientToScreen(hWnd: HWND, lpPoint: *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetCursor(hCursor: ?HCURSOR) callconv(WINAPI) ?HCURSOR;
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(WINAPI) BOOL;
pub extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(WINAPI) BOOL;

// PeekMessage flags
pub const PM_REMOVE: UINT = 0x0001;

// MapVirtualKey types
pub const MAPVK_VK_TO_CHAR: UINT = 2;

// Virtual key codes
pub const VK_RETURN: INT = 0x0D;
pub const VK_SHIFT: INT = 0x10;
pub const VK_CONTROL: INT = 0x11;
pub const VK_MENU: INT = 0x12;
pub const VK_CAPITAL: INT = 0x14;
pub const VK_ESCAPE: INT = 0x1B;
pub const VK_LWIN: INT = 0x5B;
pub const VK_RWIN: INT = 0x5C;
pub const VK_NUMLOCK: INT = 0x90;
pub const VK_RSHIFT: INT = 0xA1;
pub const VK_RCONTROL: INT = 0xA3;
pub const VK_RMENU: INT = 0xA5;

// Get mouse position macros
pub inline fn GET_X_LPARAM(lp: LPARAM) i32 {
    return @as(i16, @truncate(lp));
}
pub inline fn GET_Y_LPARAM(lp: LPARAM) i32 {
    return @as(i16, @truncate(lp >> 16));
}
pub inline fn GET_WHEEL_DELTA_WPARAM(wp: WPARAM) i16 {
    return @as(i16, @bitCast(@as(u16, @truncate(wp >> 16))));
}
pub const WHEEL_DELTA: i16 = 120;

// Clipboard constants
pub const CF_UNICODETEXT: u32 = 13;
pub const GMEM_MOVEABLE: u32 = 0x0002;

// Clipboard functions
pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
pub extern "user32" fn GetClipboardData(uFormat: u32) callconv(WINAPI) ?HANDLE;
pub extern "user32" fn SetClipboardData(uFormat: u32, hMem: ?HANDLE) callconv(WINAPI) ?HANDLE;

// Global memory functions
pub extern "kernel32" fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(WINAPI) ?HANDLE;
pub extern "kernel32" fn GlobalLock(hMem: ?HANDLE) callconv(WINAPI) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: ?HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn GlobalFree(hMem: ?HANDLE) callconv(WINAPI) ?HANDLE;

// Icon loading
pub extern "user32" fn LoadIconW(hInstance: ?HMODULE, lpIconName: ?*const anyopaque) callconv(WINAPI) ?HICON;

// Kernel32 functions
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(WINAPI) ?HMODULE;
pub extern "kernel32" fn GetLastError() callconv(WINAPI) DWORD;

// GDI32 functions
pub extern "gdi32" fn GetDC(hWnd: ?HWND) callconv(WINAPI) ?HDC;
pub extern "gdi32" fn ReleaseDC(hWnd: HWND, hDC: HDC) callconv(WINAPI) INT;
pub extern "gdi32" fn ChoosePixelFormat(hdc: ?HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(WINAPI) INT;
pub extern "gdi32" fn SetPixelFormat(hdc: ?HDC, format: INT, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(WINAPI) BOOL;
pub extern "gdi32" fn SwapBuffers(hdc: ?HDC) callconv(WINAPI) BOOL;

// Child window style
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_EX_CLIENTEDGE: DWORD = 0x00000200;

// Edit control styles
pub const ES_LEFT: DWORD = 0x0000;
pub const ES_AUTOHSCROLL: DWORD = 0x0080;

// Edit control messages
pub const EM_SETSEL: UINT = 0x00B1;
pub const EN_CHANGE: UINT = 0x0300;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_SETFONT: UINT = 0x0030;
pub const WM_GETTEXT: UINT = 0x000D;
pub const WM_SETTEXT: UINT = 0x000C;
pub const WM_CONTEXTMENU: UINT = 0x007B;

// HIWORD/LOWORD helpers
pub inline fn LOWORD(v: anytype) u16 {
    const val: usize = @bitCast(@as(isize, @intCast(v)));
    return @truncate(val);
}
pub inline fn HIWORD(v: anytype) u16 {
    const val: usize = @bitCast(@as(isize, @intCast(v)));
    return @truncate(val >> 16);
}

// Context menu / popup menu / menu bar
pub const MF_STRING: UINT = 0x00000000;
pub const MF_SEPARATOR: UINT = 0x00000800;
pub const MF_POPUP: UINT = 0x00000010;
pub const TPM_LEFTALIGN: UINT = 0x0000;
pub const TPM_TOPALIGN: UINT = 0x0000;
pub const TPM_RETURNCMD: UINT = 0x0100;

pub extern "user32" fn CreateMenu() callconv(WINAPI) ?HMENU;
pub extern "user32" fn CreatePopupMenu() callconv(WINAPI) ?HMENU;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(WINAPI) BOOL;
pub extern "user32" fn SetMenu(hWnd: HWND, hMenu: ?HMENU) callconv(WINAPI) BOOL;
pub extern "user32" fn DrawMenuBar(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: usize, lpNewItem: ?[*:0]const u16) callconv(WINAPI) BOOL;
pub extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: INT, y: INT, nReserved: INT, hWnd: HWND, prcRect: ?*const RECT) callconv(WINAPI) BOOL;

// Window positioning
pub extern "user32" fn MoveWindow(hWnd: HWND, X: INT, Y: INT, nWidth: INT, nHeight: INT, bRepaint: BOOL) callconv(WINAPI) BOOL;
pub extern "user32" fn SetFocus(hWnd: ?HWND) callconv(WINAPI) ?HWND;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(WINAPI) LRESULT;
pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(WINAPI) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(WINAPI) BOOL;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: INT, Y: INT, cx: INT, cy: INT, uFlags: UINT) callconv(WINAPI) BOOL;

// SetWindowPos constants
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_FRAMECHANGED: UINT = 0x0020;

// HWND_TOPMOST / HWND_NOTOPMOST as HWND sentinel values
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

// Monitor
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(WINAPI) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(WINAPI) BOOL;

pub const HMONITOR = *opaque {};
pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

// GDI drawing
pub const HFONT = *opaque {};
pub extern "gdi32" fn CreateFontW(
    cHeight: INT,
    cWidth: INT,
    cEscapement: INT,
    cOrientation: INT,
    cWeight: INT,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: ?[*:0]const u16,
) callconv(WINAPI) ?HFONT;
pub extern "gdi32" fn DeleteObject(ho: *anyopaque) callconv(WINAPI) BOOL;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: *anyopaque) callconv(WINAPI) ?*anyopaque;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: INT) callconv(WINAPI) INT;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: DWORD) callconv(WINAPI) DWORD;
pub extern "gdi32" fn FillRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(WINAPI) INT;
pub extern "gdi32" fn TextOutW(hdc: HDC, x: INT, y: INT, lpString: [*]const u16, c: INT) callconv(WINAPI) BOOL;
pub extern "gdi32" fn CreateSolidBrush(color: DWORD) callconv(WINAPI) ?HBRUSH;

// Background mode constants
pub const TRANSPARENT: INT = 1;

// Font weight constants
pub const FW_NORMAL: INT = 400;

// Charset
pub const DEFAULT_CHARSET: DWORD = 1;

// IME (IMM32). Windows delivers composition state through the input context
// attached to the focused window rather than through key messages.
pub const HIMC = *opaque {};

/// ImmGetCompositionStringW index: the in-progress composition text.
pub const GCS_COMPSTR: DWORD = 0x0008;
/// ImmGetCompositionStringW index: the finalized text, ready to commit.
pub const GCS_RESULTSTR: DWORD = 0x0800;

pub const CFS_POINT: DWORD = 0x0002;
pub const CFS_CANDIDATEPOS: DWORD = 0x0040;

pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD = 0,
    ptCurrentPos: POINT = .{},
    rcArea: RECT = .{},
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD = 0,
    dwStyle: DWORD = 0,
    ptCurrentPos: POINT = .{},
    rcArea: RECT = .{},
};

pub extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(WINAPI) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: HIMC) callconv(WINAPI) BOOL;
/// Returns a size in BYTES (not UTF-16 units), or a negative error code.
/// Pass a null buffer with length 0 to query the required size.
pub extern "imm32" fn ImmGetCompositionStringW(
    hIMC: HIMC,
    dwIndex: DWORD,
    lpBuf: ?*anyopaque,
    dwBufLen: DWORD,
) callconv(WINAPI) LONG;
pub extern "imm32" fn ImmSetCompositionWindow(hIMC: HIMC, lpCompForm: *const COMPOSITIONFORM) callconv(WINAPI) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(hIMC: HIMC, lpCandidate: *const CANDIDATEFORM) callconv(WINAPI) BOOL;

// OpenGL32 (WGL) functions
pub extern "opengl32" fn wglCreateContext(hdc: ?HDC) callconv(WINAPI) ?HGLRC;
pub extern "opengl32" fn wglDeleteContext(hglrc: ?HGLRC) callconv(WINAPI) BOOL;
pub extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, hglrc: ?HGLRC) callconv(WINAPI) BOOL;
pub extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(WINAPI) ?*anyopaque;
