package simple_shm

import "base:runtime"
import "core:c/libc"
import "core:container/intrusive/list"
import "core:flags"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import wl "wayland:wayland"
import xdg "wayland:wayland/stable/xdg-shell"

/*
 * This is an adaptation of the simple-shm client from Weston.
 * https://gitlab.freedesktop.org/wayland/weston/-/blob/main/clients/simple-shm.c
 *
 *
 * Copyright © 2011 Benjamin Franzke
 * Copyright © 2010 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

KEY_ESC :: 1
KEY_Q :: 16
KEY_F11 :: 87

MAX_BUFFER_ALLOC :: 2

Format :: struct {
	code:  wl.Shm_Format,
	str:   string,
	bpp:   int,
	color: [4]u64,
}

Display :: struct {
	display:      ^wl.Display,
	registry:     ^wl.Registry,
	compositor:   ^wl.Compositor,
	wm_base:      ^xdg.Wm_Base,
	seat:         ^wl.Seat,
	pointer:      ^wl.Pointer,
	keyboard:     ^wl.Keyboard,
	shm:          ^wl.Shm,
	format:       ^Format,
	paint_format: bool,
	has_format:   bool,
}

Buffer :: struct {
	using node:    list.Node,
	window:        ^Window,
	buffer:        ^wl.Buffer,
	shm_data:      rawptr,
	busy:          bool,
	width, height: int,
	size:          uint,
}

Window :: struct {
	display:                 ^Display,
	width, height:           int,
	init_width, init_height: int,
	surface:                 ^wl.Surface,
	xdg_surface:             ^xdg.Surface,
	xdg_toplevel:            ^xdg.Toplevel,
	buffer_list:             list.List,
	callback:                ^wl.Callback,
	wait_for_configure:      bool,
	maximized:               bool,
	fullscreen:              bool,
	needs_update_buffer:     bool,
	pointer_inside:          bool,
	pointer_pressed:         bool,
	pointer_x, pointer_y:    int,
}

running := true
global_context: runtime.Context
active_window: ^Window

shm_formats: []Format = {
	// Keep this small and practical for the example.
	{.Xrgb8888, "Xrgb8888", 32, {0xffff0000, 0xff00ff00, 0xff0000ff, 0x7f7f7f7f}},
	{.Argb8888, "Argb8888", 32, {0xffff0000, 0xff00ff00, 0xff0000ff, 0x7f7f7f7f}},
	{.Rgb565, "Rgb565", 16, {0xf800, 0x07e0, 0x001f, 0xffff}},
}

alloc_buffer :: proc(window: ^Window, width, height: int) -> ^Buffer {
	buffer := new(Buffer)
	buffer.window = window
	buffer.width = width
	buffer.height = height
	return buffer
}

destroy_buffer :: proc(buffer: ^Buffer) {
	if buffer.buffer != nil {
		wl.buffer_destroy(buffer.buffer)
	}

	posix.munmap(buffer.shm_data, buffer.size)
	free(buffer)
}

pick_free_buffer :: proc(window: ^Window) -> ^Buffer {
	iter := list.iterator_head(window.buffer_list, Buffer, "node")
	for buffer in list.iterate_next(&iter) {
		if !buffer.busy {
			return buffer
		}
	}

	return nil
}

prune_old_released_buffers :: proc(window: ^Window) {
	for node := window.buffer_list.head; node != nil; {
		next := node.next
		buffer := container_of(node, Buffer, "node")
		if !buffer.busy &&
		   (buffer.width != buffer.window.width || buffer.height != buffer.window.height) {
			list.remove(&window.buffer_list, node)
			destroy_buffer(buffer)
		}
		node = next
	}
}

create_anonymous_file :: proc(size: uint) -> posix.FD {
	TEMPLATE :: "/odin-wl-shared-XXXXXX"

	path := libc.getenv("XDG_RUNTIME_DIR")
	if path == nil {
		posix.set_errno(.ENOENT)
		return -1
	}

	name := fmt.ctprintf("%v%v", path, TEMPLATE)
	fd := posix.mkstemp(name)
	if fd >= 0 {
		flags := posix.fcntl(fd, .GETFD)
		if flags == -1 {
			posix.close(fd)
			return -1
		}

		if posix.fcntl(fd, .SETFD, flags | posix.FD_CLOEXEC) < 0 {
			posix.close(fd)
			return -1
		}

		posix.unlink(name)
	}

	for {
		ret := posix.ftruncate(fd, posix.off_t(size))
		if ret == .OK {
			break
		}

		if posix.get_errno() != .EINTR {
			posix.close(fd)
			return -1
		}
	}

	return fd
}

create_shm_buffer :: proc(window: ^Window, buffer: ^Buffer, format: ^Format) -> bool {
	stride := window.width * (format.bpp / 8)
	size := stride * window.height

	fd := create_anonymous_file(uint(size))
	if fd < 0 {
		fmt.eprintfln(
			"Failed to create a %v Bytes buffer: %v",
			size,
			posix.strerror(posix.get_errno()),
		)
		return false
	}

	data := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if data == posix.MAP_FAILED {
		fmt.eprintfln("mmap failed: %v", posix.strerror(posix.get_errno()))
		posix.close(fd)
		return false
	}

	pool := wl.shm_create_pool(window.display.shm, i32(fd), i32(size))
	buffer.buffer = wl.shm_pool_create_buffer(
		pool,
		0,
		i32(window.width),
		i32(window.height),
		i32(stride),
		format.code,
	)
	wl.buffer_add_listener(buffer.buffer, &buffer_listener, buffer)
	wl.shm_pool_destroy(pool)
	posix.close(fd)

	buffer.size = uint(size)
	buffer.shm_data = data

	return true
}

buffer_release :: proc "c" (data: rawptr, buffer: ^wl.Buffer) {
	mybuf := cast(^Buffer)data
	mybuf.busy = false
}

buffer_listener: wl.Buffer_Listener = {
	release = buffer_release,
}

xdg_surface_configure :: proc "c" (data: rawptr, surface: ^xdg.Surface, serial: u32) {
	window := cast(^Window)data

	xdg.surface_ack_configure(surface, serial)

	if window.wait_for_configure {
		redraw(window, nil, 0)
		window.wait_for_configure = false
	}
}

xdg_surface_listener: xdg.Surface_Listener = {
	configure = xdg_surface_configure,
}

toplevel_configure :: proc "c" (
	data: rawptr,
	toplevel: ^xdg.Toplevel,
	width: i32,
	height: i32,
	states: ^wl.Array,
) {
	window := cast(^Window)data

	window.fullscreen = false
	window.maximized = false

	if states != nil && states.data != nil {
		state_count := int(states.size / size_of(u32))
		state_values := cast([^]u32)states.data
		for i in 0 ..< state_count {
			#partial switch xdg.Toplevel_State(state_values[i]) {
			case .Fullscreen:
				window.fullscreen = true
			case .Maximized:
				window.maximized = true
			}
		}
	}

	if width > 0 && height > 0 {
		if !window.fullscreen && !window.maximized {
			window.init_width = int(width)
			window.init_height = int(height)
		}
		window.width = int(width)
		window.height = int(height)
	} else if !window.fullscreen && !window.maximized {
		window.width = window.init_width
		window.height = window.init_height
	}

	window.needs_update_buffer = true
}

toplevel_close :: proc "c" (data: rawptr, toplevel: ^xdg.Toplevel) {
	running = false
}

toplevel_listener: xdg.Toplevel_Listener = {
	configure = toplevel_configure,
	close     = toplevel_close,
}

wm_base_ping :: proc "c" (data: rawptr, wm_base: ^xdg.Wm_Base, serial: u32) {
	xdg.wm_base_pong(wm_base, serial)
}

wm_base_listener: xdg.Wm_Base_Listener = {
	ping = wm_base_ping,
}

keyboard_keymap :: proc "c" (
	data: rawptr,
	keyboard: ^wl.Keyboard,
	format: wl.Keyboard_Keymap_Format,
	fd: i32,
	size: u32,
) {
	context = runtime.default_context()
	os.close(os.Handle(fd)) // Don’t leak the keymap fd.
}

keyboard_enter :: proc "c" (
	data: rawptr,
	keyboard: ^wl.Keyboard,
	serial: u32,
	surface: ^wl.Surface,
	keys: ^wl.Array,
) {}
keyboard_leave :: proc "c" (
	data: rawptr,
	keyboard: ^wl.Keyboard,
	serial: u32,
	surface: ^wl.Surface,
) {}

keyboard_key :: proc "c" (
	data: rawptr,
	keyboard: ^wl.Keyboard,
	serial: u32,
	time: u32,
	key: u32,
	state: wl.Keyboard_Key_State,
) {
	window := active_window
	if window == nil {
		return
	}

	if key == KEY_F11 && state == .Pressed {
		if window.fullscreen {
			xdg.toplevel_unset_fullscreen(window.xdg_toplevel)
		} else {
			xdg.toplevel_set_fullscreen(window.xdg_toplevel, nil)
		}
		return
	}

	if (key == KEY_ESC || key == KEY_Q) && state == .Pressed {
		running = false
	}
}

keyboard_modifiers :: proc "c" (
	data: rawptr,
	keyboard: ^wl.Keyboard,
	serial: u32,
	mods_depressed: u32,
	mods_latched: u32,
	mods_locked: u32,
	group: u32,
) {}
keyboard_repeat_info :: proc "c" (data: rawptr, keyboard: ^wl.Keyboard, rate: i32, delay: i32) {}

keyboard_listener: wl.Keyboard_Listener = {
	keymap      = keyboard_keymap,
	enter       = keyboard_enter,
	leave       = keyboard_leave,
	key         = keyboard_key,
	modifiers   = keyboard_modifiers,
	repeat_info = keyboard_repeat_info,
}

fixed_to_int :: proc "contextless" (value: wl.Fixed) -> int {
	return int(value >> 8)
}

pointer_enter :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	serial: u32,
	surface: ^wl.Surface,
	surface_x: wl.Fixed,
	surface_y: wl.Fixed,
) {
	window := active_window
	if window == nil || surface != window.surface {
		return
	}

	window.pointer_inside = true
	window.pointer_x = fixed_to_int(surface_x)
	window.pointer_y = fixed_to_int(surface_y)
}

pointer_leave :: proc "c" (data: rawptr, pointer: ^wl.Pointer, serial: u32, surface: ^wl.Surface) {
	window := active_window
	if window == nil || surface != window.surface {
		return
	}

	window.pointer_inside = false
	window.pointer_pressed = false
}

pointer_motion :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	time: u32,
	surface_x: wl.Fixed,
	surface_y: wl.Fixed,
) {
	window := active_window
	if window == nil {
		return
	}

	window.pointer_x = fixed_to_int(surface_x)
	window.pointer_y = fixed_to_int(surface_y)
}

pointer_button :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	serial: u32,
	time: u32,
	button: u32,
	state: wl.Pointer_Button_State,
) {
	window := active_window
	if window == nil {
		return
	}

	window.pointer_pressed = state == .Pressed
}

pointer_axis :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	time: u32,
	axis: wl.Pointer_Axis,
	value: wl.Fixed,
) {}

pointer_frame :: proc "c" (data: rawptr, pointer: ^wl.Pointer) {}
pointer_axis_source :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	axis_source: wl.Pointer_Axis_Source,
) {}
pointer_axis_stop :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	time: u32,
	axis: wl.Pointer_Axis,
) {}
pointer_axis_discrete :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	axis: wl.Pointer_Axis,
	discrete: i32,
) {}
pointer_axis_value120 :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	axis: wl.Pointer_Axis,
	value120: i32,
) {}
pointer_axis_relative_direction :: proc "c" (
	data: rawptr,
	pointer: ^wl.Pointer,
	axis: wl.Pointer_Axis,
	direction: wl.Pointer_Axis_Relative_Direction,
) {}

pointer_listener: wl.Pointer_Listener = {
	enter                   = pointer_enter,
	leave                   = pointer_leave,
	motion                  = pointer_motion,
	button                  = pointer_button,
	axis                    = pointer_axis,
	frame                   = pointer_frame,
	axis_source             = pointer_axis_source,
	axis_stop               = pointer_axis_stop,
	axis_discrete           = pointer_axis_discrete,
	axis_value120           = pointer_axis_value120,
	axis_relative_direction = pointer_axis_relative_direction,
}

seat_capabilities :: proc "c" (data: rawptr, seat: ^wl.Seat, caps: wl.Seat_Capability) {
	display := cast(^Display)data

	if (caps & .Pointer) == .Pointer && display.pointer == nil {
		display.pointer = wl.seat_get_pointer(seat)
		wl.pointer_add_listener(display.pointer, &pointer_listener, data)
	} else if (caps & .Pointer) != .Pointer && display.pointer != nil {
		wl.pointer_destroy(display.pointer)
		display.pointer = nil
	}

	if (caps & .Keyboard) == .Keyboard && display.keyboard == nil {
		display.keyboard = wl.seat_get_keyboard(seat)
		wl.keyboard_add_listener(display.keyboard, &keyboard_listener, data)
	} else if (caps & .Keyboard) != .Keyboard && display.keyboard != nil {
		wl.keyboard_destroy(display.keyboard)
		display.keyboard = nil
	}
}

seat_listener: wl.Seat_Listener = {
	capabilities = seat_capabilities,
}

shm_format :: proc "c" (data: rawptr, shm: ^wl.Shm, format: wl.Shm_Format) {
	display := cast(^Display)data
	if format == display.format.code {
		display.has_format = true
	}
}

shm_listener: wl.Shm_Listener = {
	format = shm_format,
}

registry_global :: proc "c" (
	data: rawptr,
	registry: ^wl.Registry,
	name: u32,
	interface: cstring,
	version: u32,
) {
	display := cast(^Display)data

	switch interface {
	case wl.compositor_interface.name:
		display.compositor = cast(^wl.Compositor)wl.registry_bind(
			registry,
			name,
			&wl.compositor_interface,
			1,
		)
	case xdg.wm_base_interface.name:
		display.wm_base = cast(^xdg.Wm_Base)wl.registry_bind(
			registry,
			name,
			&xdg.wm_base_interface,
			1,
		)
		xdg.wm_base_add_listener(display.wm_base, &wm_base_listener, data)
	case wl.seat_interface.name:
		display.seat = cast(^wl.Seat)wl.registry_bind(registry, name, &wl.seat_interface, 1)
		wl.seat_add_listener(display.seat, &seat_listener, data)
	case wl.shm_interface.name:
		display.shm = cast(^wl.Shm)wl.registry_bind(registry, name, &wl.shm_interface, 1)
		wl.shm_add_listener(display.shm, &shm_listener, data)
	}
}

registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {}

registry_listener: wl.Registry_Listener = {
	global        = registry_global,
	global_remove = registry_global_remove,
}

get_next_buffer :: proc(window: ^Window) -> ^Buffer {
	if window.needs_update_buffer {
		for i in 0 ..< MAX_BUFFER_ALLOC {
			buffer := alloc_buffer(window, window.width, window.height)
			list.push_back(&window.buffer_list, buffer)
		}
		window.needs_update_buffer = false
	}

	buffer := pick_free_buffer(window)
	if buffer == nil {
		return nil
	}

	if buffer.buffer == nil {
		if !create_shm_buffer(window, buffer, window.display.format) {
			return nil
		}

		// Paint the padding
		runtime.memset(
			buffer.shm_data,
			0xff,
			window.width * window.height * (window.display.format.bpp / 8),
		)
	}

	return buffer
}

clamp_int :: proc(value, min_value, max_value: int) -> int {
	if value < min_value {
		return min_value
	}
	if value > max_value {
		return max_value
	}
	return value
}

paint_pixels :: proc(
	image: rawptr,
	padding, width, height: u32,
	time: u32,
	pointer_inside, pointer_pressed: bool,
	pointer_x, pointer_y: int,
) {
	padding_i := int(padding)
	width_i := int(width)
	height_i := int(height)

	center_x := padding_i + (width_i - padding_i * 2) / 2
	center_y := padding_i + (height_i - padding_i * 2) / 2
	if pointer_inside {
		center_x = clamp_int(pointer_x, padding_i, width_i - padding_i - 1)
		center_y = clamp_int(pointer_y, padding_i, height_i - padding_i - 1)
	}

	// Squared radii thresholds
	or := center_x - padding_i
	if center_y - padding_i < or {
		or = center_y - padding_i
	}
	if width_i - padding_i - center_x < or {
		or = width_i - padding_i - center_x
	}
	if height_i - padding_i - center_y < or {
		or = height_i - padding_i - center_y
	}
	or -= 8
	if or < 16 {
		or = 16
	}
	ir := or - 32
	if ir < 4 {
		ir = 4
	}
	or2 := or * or
	ir2 := ir * ir

	pixel := cast([^]u32)image
	offset: u32

	offset += padding * width
	for y := padding_i; y < height_i - padding_i; y += 1 {
		y2 := (y - center_y) * (y - center_y)

		offset += padding
		for x := padding_i; x < width_i - padding_i; x += 1 {
			// Squared distance from center
			r2 := (x - center_x) * (x - center_x) + y2

			v: u32
			if r2 < ir2 {
				v = u32(r2 / 32 + int(time) / 64) * 0x0080401
			} else if r2 < or2 {
				v = u32(y + int(time) / 32) * 0x0080401
			} else {
				v = u32(x + int(time) / 32) * 0x0080401
			}
			v &= 0x00ffffff

			if pointer_inside {
				dp2 := (x - pointer_x) * (x - pointer_x) + (y - pointer_y) * (y - pointer_y)
				if dp2 < 64 {
					if pointer_pressed {
						v = 0x00ff5050
					} else {
						v = 0x00ffffff
					}
				} else if dp2 < 1600 {
					if pointer_pressed {
						v ~= 0x00500000
					} else {
						v ~= 0x00004080
					}
				}
			}

			// Cross if compositor uses X from XRGB as alpha
			if abs(x - y) > 6 && abs(x + y - height_i) > 6 {
				v |= 0xff000000
			}

			pixel[offset] = v
			offset += 1
		}

		offset += padding
	}
}

redraw :: proc "c" (data: rawptr, callback: ^wl.Callback, time: u32) {
	context = global_context
	window := cast(^Window)data

	prune_old_released_buffers(window)

	buffer := get_next_buffer(window)
	if buffer == nil {
		if callback == nil {
			panic("Failed to create first buffer.")
		} else {
			panic("All buffers busy at redraw().")
		}
	}

	paint_pixels(
		buffer.shm_data,
		20,
		u32(window.width),
		u32(window.height),
		time,
		window.pointer_inside,
		window.pointer_pressed,
		window.pointer_x,
		window.pointer_y,
	)

	wl.surface_attach(window.surface, buffer.buffer, 0, 0)
	wl.surface_damage(window.surface, 0, 0, i32(window.width), i32(window.height))

	if callback != nil {
		wl.callback_destroy(callback)
	}

	window.callback = wl.surface_frame(window.surface)
	wl.callback_add_listener(window.callback, &frame_listener, window)
	wl.surface_commit(window.surface)
	buffer.busy = true
}

frame_listener: wl.Callback_Listener = {
	done = redraw,
}

create_window :: proc(display: ^Display, width, height: int) -> (^Window, bool) {
	window := new(Window)

	window.display = display
	window.width = width
	window.height = height
	window.init_width = width
	window.init_height = height
	window.surface = wl.compositor_create_surface(display.compositor)

	if display.wm_base == nil {
		free(window)
		return nil, false
	}

	window.xdg_surface = xdg.wm_base_get_xdg_surface(display.wm_base, window.surface)
	ensure(window.xdg_surface != nil)
	xdg.surface_add_listener(window.xdg_surface, &xdg_surface_listener, window)

	window.xdg_toplevel = xdg.surface_get_toplevel(window.xdg_surface)
	ensure(window.xdg_toplevel != nil)
	xdg.toplevel_add_listener(window.xdg_toplevel, &toplevel_listener, window)

	xdg.toplevel_set_title(window.xdg_toplevel, "simple-shm")
	xdg.toplevel_set_app_id(window.xdg_toplevel, "simple-shm")

	wl.surface_commit(window.surface)
	window.wait_for_configure = true

	for i in 0 ..< MAX_BUFFER_ALLOC {
		buffer := alloc_buffer(window, window.width, window.height)
		list.push_back(&window.buffer_list, buffer)
	}

	return window, true
}

destroy_window :: proc(window: ^Window) {
	if window.callback != nil {
		wl.callback_destroy(window.callback)
	}

	for node := window.buffer_list.head; node != nil; {
		next := node.next
		buffer := container_of(node, Buffer, "node")
		list.remove(&window.buffer_list, node)
		destroy_buffer(buffer)
		node = next
	}

	if window.xdg_toplevel != nil {
		xdg.toplevel_destroy(window.xdg_toplevel)
	}

	if window.xdg_surface != nil {
		xdg.surface_destroy(window.xdg_surface)
	}

	wl.surface_destroy(window.surface)
	free(window)
}

create_display :: proc(format: ^Format, paint_format: bool) -> (^Display, bool) {
	display := new(Display)

	display.display = wl.display_connect(nil)
	if display.display == nil {
		fmt.eprintln("Failed to connect to Wayland display")
		free(display)
		return {}, false
	}

	display.format = format
	display.paint_format = paint_format

	display.registry = wl.display_get_registry(display.display)
	if display.registry == nil {
		fmt.eprintln("Failed to get registry")
		free(display)
		return {}, false
	}

	wl.registry_add_listener(display.registry, &registry_listener, display)
	wl.display_roundtrip(display.display)
	if display.shm == nil {
		fmt.eprintln("No wl_shm global")
		free(display)
		return {}, false
	}

	wl.display_roundtrip(display.display)

	if !display.has_format {
		fmt.eprintfln("Format '%v' not supported by compositor.", format.str)
		free(display)
		return {}, false
	}

	return display, true
}

destroy_display :: proc(display: ^Display) {
	if display.shm != nil {
		wl.shm_destroy(display.shm)
	}

	if display.pointer != nil {
		wl.pointer_destroy(display.pointer)
	}

	if display.keyboard != nil {
		wl.keyboard_destroy(display.keyboard)
	}

	if display.seat != nil {
		wl.seat_destroy(display.seat)
	}

	if display.wm_base != nil {
		xdg.wm_base_destroy(display.wm_base)
	}

	if display.compositor != nil {
		wl.compositor_destroy(display.compositor)
	}

	wl.registry_destroy(display.registry)
	wl.display_flush(display.display)
	wl.display_disconnect(display.display)
	free(display)
}

signal_int :: proc "c" (signal: posix.Signal) {
	running = false
}

main :: proc() {
	global_context = context

	options: struct {
		format: wl.Shm_Format `usage:"Test Format."`,
	}
	options.format = wl.Shm_Format(-1)
	flags.parse_or_exit(&options, os.args, .Unix)

	format: ^Format
	paint_format: bool
	for &f in shm_formats {
		if f.code == options.format {
			format = &f
			paint_format = true
		}
	}
	if format == nil {
		for &f in shm_formats {
			if f.code == .Xrgb8888 {
				format = &f
			}
		}
	}

	display, display_ok := create_display(format, paint_format)
	if !display_ok {
		os.exit(1)
	}
	defer destroy_display(display)

	window, window_ok := create_window(display, 512, 512)
	if !window_ok {
		os.exit(1)
	}
	defer destroy_window(window)
	active_window = window
	defer active_window = nil

	sigint: posix.sigaction_t
	sigint.sa_handler = signal_int
	posix.sigemptyset(&sigint.sa_mask)
	sigint.sa_flags = {.RESETHAND}
	posix.sigaction(.SIGINT, &sigint, nil)

	wl.surface_damage(window.surface, 0, 0, i32(window.width), i32(window.height))

	if !window.wait_for_configure {
		redraw(window, nil, 0)
	}

	for running {
		if wl.display_dispatch(display.display) == -1 {
			break
		}
	}
}
