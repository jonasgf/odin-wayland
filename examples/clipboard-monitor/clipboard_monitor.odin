package clipboard_monitor

import "base:runtime"
import "core:fmt"
import os "core:os/os2"
import wl "wayland:wayland"
import ext "wayland:wayland/staging/ext-data-control"

Clipboard :: struct {
	ctx:           runtime.Context,
	manager:       ^ext.Data_Control_Manager_V1,
	seat:          ^wl.Seat,
	current_offer: ^ext.Data_Control_Offer_V1,
}

main :: proc() {
	clipboard: Clipboard
	clipboard.ctx = context

	display := wl.display_connect(nil)
	if display == nil {
		fmt.eprintln("Failed to connect to Wayland display")
		return
	}
	defer wl.display_disconnect(display)

	registry := wl.display_get_registry(display)
	if registry == nil {
		fmt.eprintln("Failed to get registry")
		return
	}
	wl.registry_add_listener(registry, &registry_listener, &clipboard)
	wl.display_roundtrip(display)

	if clipboard.seat == nil || clipboard.manager == nil {
		fmt.eprintln("Failed to bind seat or data control manager")
		return
	}

	data_device := ext.data_control_manager_v1_get_data_device(clipboard.manager, clipboard.seat)
	if data_device == nil {
		fmt.eprintln("Failed to get data device")
		return
	}

	ext.data_control_device_v1_add_listener(data_device, &data_control_device_listener, &clipboard)
	wl.display_roundtrip(display)

	for {
		free_all(context.temp_allocator)

		for clipboard.current_offer == nil {
			if wl.display_dispatch(display) < 0 {
				fmt.eprintln("Display dispatch failed")
				return
			}
		}

		rd, wr, err := os.pipe()
		if err != nil {
			fmt.eprintln("Failed to create pipe:", err)
			return
		}
		defer os.close(rd)

		ext.data_control_offer_v1_receive(clipboard.current_offer, "text/plain", i32(os.fd(wr)))
		os.close(wr)
		wl.display_flush(display)

		data, read_err := os.read_entire_file(rd, context.temp_allocator)
		if read_err != nil {
			fmt.eprintln("Failed to read clipboard:", read_err)
			return
		}

		fmt.println(string(data))

		ext.data_control_offer_v1_destroy(clipboard.current_offer)
		clipboard.current_offer = nil
	}
}

registry_global :: proc "c" (
	data: rawptr,
	registry: ^wl.Registry,
	name: u32,
	interface: cstring,
	version: u32,
) {
	clipboard := cast(^Clipboard)data
	switch interface {
	case wl.seat_interface.name:
		clipboard.seat = cast(^wl.Seat)wl.registry_bind(
			registry,
			name,
			&wl.seat_interface,
			version,
		)
	case ext.data_control_manager_v1_interface.name:
		clipboard.manager = cast(^ext.Data_Control_Manager_V1)wl.registry_bind(
			registry,
			name,
			&ext.data_control_manager_v1_interface,
			version,
		)
	}
}

registry_global_remove :: proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {
}

registry_listener: wl.Registry_Listener = {
	global        = registry_global,
	global_remove = registry_global_remove,
}

selection :: proc "c" (
	data: rawptr,
	device: ^ext.Data_Control_Device_V1,
	offer: ^ext.Data_Control_Offer_V1,
) {
	clipboard := cast(^Clipboard)data
	context = clipboard.ctx

	if offer == nil {
		return
	}

	if clipboard.current_offer != nil {
		ext.data_control_offer_v1_destroy(offer)
		return
	}

	clipboard.current_offer = offer
}

data_offer :: proc "c" (
	data: rawptr,
	device: ^ext.Data_Control_Device_V1,
) -> ^ext.Data_Control_Offer_V1 {
	return nil
}

finished :: proc "c" (data: rawptr, device: ^ext.Data_Control_Device_V1) {
}

primary_selection :: proc "c" (
	data: rawptr,
	device: ^ext.Data_Control_Device_V1,
	offer: ^ext.Data_Control_Offer_V1,
) {
}

data_control_device_listener: ext.Data_Control_Device_V1_Listener = {
	data_offer        = data_offer,
	selection         = selection,
	finished          = finished,
	primary_selection = primary_selection,
}
