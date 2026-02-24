package scanner

import "core:encoding/xml"
import "core:flags"
import "core:fmt"
import os "core:os/os2"
import "core:strings"
import "core:unicode"

Argument_Type :: enum {
	New_ID,
	Int,
	Unsigned,
	Fixed,
	String,
	Object,
	Array,
	FD,
}

Argument :: struct {
	name:                 string,
	type:                 Argument_Type,
	nullable:             bool,
	enumeration_name:     string,
	enumeration_name_ada: string,
	enumeration_prefix:   string,
	prefix:               string,
	interface_name:       string,
	interface_name_ada:   string,
	summary:              string,
}

Description :: struct {
	summary: string,
	text:    string,
}

Protocol :: struct {
	name:               string,
	copyright:          string,
	description:        Description,
	interfaces:         [dynamic]^Interface,
	null_run_length:    int,
	type_index_counter: int,
}

Interface :: struct {
	name:         string,
	name_ada:     string,
	name_upper:   string,
	full_name:    string,
	version:      string,
	description:  Description,
	enumerations: [dynamic]^Enumeration,
	requests:     [dynamic]^Message,
	events:       [dynamic]^Message,
}

Enumeration_Entry :: struct {
	name:             string,
	name_ada:         string,
	name_upper:       string,
	value:            string,
	since:            string,
	deprecated_since: string,
	summary:          string,
	description:      Description,
}

Enumeration :: struct {
	name:        string,
	name_ada:    string,
	since:       string,
	bitfield:    bool,
	entries:     [dynamic]Enumeration_Entry,
	description: Description,
}

Message :: struct {
	name:             string,
	name_upper:       string,
	destructor:       bool,
	since:            string,
	deprecated_since: string,
	arguments:        [dynamic]^Argument,
	return_argument:  ^Argument,
	new_id_argument:  ^Argument,
	all_null:         bool,
	type_index:       int,
	description:      Description,
}

Emit_Context :: struct {
	file:            ^os.File,
	output:          strings.Builder,
	emit_comments:   bool,
	is_wayland_core: bool,
	wayland_prefix:  string,
}

main :: proc() {
	options: struct {
		input_file:   string `args:"pos=0,required" usage:"Input protocol XML file."`,
		output_file:  string `args:"pos=1,required" usage:"Output Odin file."`,
		package_name: string `args:"name=package" usage:"Package name. Defaults to protocol name from XML."`,
	}
	flags.parse_or_exit(&options, os.args)

	doc, xml_err := xml.load_from_file(options.input_file)
	if xml_err != .None {
		fmt.eprintfln("Failed to load XML file: %v", xml_err)
		os.exit(1)
	}
	defer xml.destroy(doc)

	protocol, protocol_ok := parse_protocol(doc)
	if !protocol_ok {
		fmt.eprintln("Failed to parse protocol.")
		os.exit(1)
	}

	package_name := options.package_name
	if package_name == "" {
		package_name = protocol.name
	}

	output_file, open_err := os.open(
		options.output_file,
		{.Create, .Trunc, .Write},
		os.Permissions_Default_File,
	)
	if open_err != nil {
		fmt.eprintfln("Failed to open output file for writing: %v", open_err)
		os.exit(1)
	}
	defer os.close(output_file)

	emit_protocol(output_file, protocol, package_name)
}

parse_protocol :: proc(doc: ^xml.Document) -> (protocol: ^Protocol, ok: bool) {
	if doc == nil || len(doc.elements) == 0 {
		fmt.eprintln("XML document is empty.")
		return
	}

	root_id := xml.Element_ID(0)
	root := doc.elements[root_id]
	if root.kind != .Element || root.ident != "protocol" {
		fmt.eprintln("XML root element must be <protocol>.")
		return
	}

	protocol = new(Protocol)
	protocol.name = get_attribute_required(doc, root_id, "name") or_return
	protocol.description = parse_description(doc, root_id) or_return

	for value in root.value {
		switch child_id in value {
		case string:
			continue
		case xml.Element_ID:
			child := doc.elements[child_id]
			if child.kind != .Element {
				continue
			}

			switch child.ident {
			case "copyright":
				protocol.copyright = element_text(doc, child_id)
			case "description":
				continue
			case "interface":
				interface := parse_interface(doc, child_id) or_return
				append(&protocol.interfaces, interface)
			case:
				continue
			}
		}
	}

	if len(protocol.interfaces) == 0 {
		fmt.eprintfln("Protocol '%v' does not define any interfaces.", protocol.name)
		return
	}

	finalize_protocol(protocol) or_return

	return protocol, true
}

emit_protocol :: proc(
	file: ^os.File,
	protocol: ^Protocol,
	package_name: string,
	comments := true,
) {
	ctx := Emit_Context {
		file            = file,
		emit_comments   = comments,
		is_wayland_core = protocol.name == "wayland",
		wayland_prefix  = "wl.",
	}
	if ctx.is_wayland_core {
		ctx.wayland_prefix = ""
	}

	strings.builder_init(&ctx.output)
	defer strings.builder_destroy(&ctx.output)

	emitln(&ctx, "package %v", package_name)
	emitln(&ctx)

	if ctx.emit_comments {
		emit_comment(&ctx, protocol.copyright)
		emitln(&ctx)
	}

	if !ctx.is_wayland_core {
		emitln(&ctx, "import \"core:c\"")
		emitln(&ctx, "import wl \"wayland:wayland\"")
		emitln(&ctx)
	}

	emit_interface_objects(&ctx, protocol)
	emit_interfaces(&ctx, protocol)

	emitln(&ctx, "@(private)")
	emitln(&ctx, "@(init)")
	emitln(&ctx, "%v_init_interfaces :: proc \"contextless\" () {", protocol.name)
	for interface in protocol.interfaces {
		emitln(&ctx, "%v_interface.name = \"%v\"", interface.name, interface.full_name, indent = 1)
		emitln(&ctx, "%v_interface.version = %v", interface.name, interface.version, indent = 1)
		emitln(
			&ctx,
			"%v_interface.method_count = %v",
			interface.name,
			len(interface.requests),
			indent = 1,
		)
		emitln(
			&ctx,
			"%v_interface.event_count = %v",
			interface.name,
			len(interface.events),
			indent = 1,
		)
		if len(interface.requests) > 0 {
			emitln(
				&ctx,
				"%v_interface.methods = raw_data(%v_requests)",
				interface.name,
				interface.name,
				indent = 1,
			)
		}
		if len(interface.events) > 0 {
			emitln(
				&ctx,
				"%v_interface.events = raw_data(%v_events)",
				interface.name,
				interface.name,
				indent = 1,
			)
		}
	}
	emitln(&ctx, "}")

	if ctx.is_wayland_core {
		emitln(&ctx)
		emitln(&ctx, CORE_WAYLAND)
	}

	_, write_err := os.write_string(file, strings.to_string(ctx.output))
	if write_err != nil {
		fmt.eprintfln("Failed to write generated file: %v", write_err)
	}
}

emit :: proc(
	ctx: ^Emit_Context,
	str: string = "",
	args: ..any,
	indent: uint = 0,
	newline: bool = false,
) {
	for i in 0 ..< indent {
		strings.write_byte(&ctx.output, '\t')
	}
	if len(args) == 0 {
		strings.write_string(&ctx.output, str)
	} else {
		escaped := str
		if strings.contains_rune(escaped, '{') {
			escaped, _ = strings.replace_all(escaped, "{", "{{")
		}
		if strings.contains_rune(escaped, '}') {
			escaped, _ = strings.replace_all(escaped, "}", "}}")
		}
		fmt.sbprintf(&ctx.output, escaped, ..args)
	}
	if newline {
		strings.write_byte(&ctx.output, '\n')
	}
}

emitln :: proc(ctx: ^Emit_Context, str: string = "", args: ..any, indent: uint = 0) {
	emit(ctx, str, ..args, indent = indent, newline = true)
}

emit_comment :: proc(ctx: ^Emit_Context, text: string, brief: string = "", indent: uint = 0) {
	write_indent :: proc(sb: ^strings.Builder, indent: uint) {
		for i in 0 ..< indent {
			strings.write_byte(sb, '\t')
		}
	}

	if !ctx.emit_comments || (len(text) == 0 && len(brief) == 0) {
		return
	}

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	short_form := brief == "" && strings.count(text, "\n") == 0

	write_indent(&sb, indent)
	strings.write_string(&sb, "/*")

	if short_form {
		strings.write_string(&sb, " ")
	} else {
		strings.write_string(&sb, "\n")
		write_indent(&sb, indent)
		strings.write_string(&sb, " * ")
	}

	if brief != "" {
		strings.write_string(&sb, brief)
		strings.write_string(&sb, "\n")

		write_indent(&sb, indent)
		strings.write_string(&sb, " *\n")
		write_indent(&sb, indent)
		strings.write_string(&sb, " * ")
	}

	line_start := true
	for r in text {
		if line_start {
			if unicode.is_white_space(r) && r != '\n' {
				continue
			}
			line_start = false
		}

		strings.write_rune(&sb, r)
		if r == '\n' {
			line_start = true
			write_indent(&sb, indent)
			strings.write_string(&sb, " * ")
		}
	}

	if !short_form {
		strings.write_string(&sb, "\n")
		write_indent(&sb, indent)
	}
	strings.write_string(&sb, " */")

	emitln(ctx, strings.to_string(sb))
}

emit_interface_objects :: proc(ctx: ^Emit_Context, protocol: ^Protocol) {
	protocol.type_index_counter = 0

	emitln(ctx, "%v_types: []^%vInterface = {", protocol.name, ctx.wayland_prefix)
	for _ in 0 ..< protocol.null_run_length {
		emitln(ctx, "nil,", indent = 1)
	}

	for interface in protocol.interfaces {
		for request in interface.requests {
			emit_message_type(ctx, protocol, request)
		}
		for event in interface.events {
			emit_message_type(ctx, protocol, event)
		}
	}
	emitln(ctx, "}")
	emitln(ctx)
}

emit_message_type :: proc(ctx: ^Emit_Context, protocol: ^Protocol, message: ^Message) {
	if message.all_null {
		message.type_index = 0
		return
	}

	message.type_index = protocol.null_run_length + protocol.type_index_counter
	arg_length := len(message.arguments)
	if message.return_argument != nil {
		arg_length += 1
	}
	protocol.type_index_counter += arg_length

	if message.return_argument != nil {
		emitln(
			ctx,
			"&%v%v_interface,",
			message.return_argument.prefix,
			message.return_argument.interface_name,
			indent = 1,
		)
	}

	for argument in message.arguments {
		if (argument.type == .New_ID || argument.type == .Object) &&
		   argument.interface_name != "" {
			emitln(ctx, "&%v%v_interface,", argument.prefix, argument.interface_name, indent = 1)
		} else {
			emitln(ctx, "nil,", indent = 1)
		}
	}
}

emit_interfaces :: proc(ctx: ^Emit_Context, protocol: ^Protocol) {
	for interface in protocol.interfaces {
		emitln(ctx, "%v :: struct {}", interface.name_ada)
		emitln(ctx)

		emit_constants(ctx, interface)
		emit_enumerations(ctx, interface)
		emit_events(ctx, interface)
		emit_requests(ctx, interface, protocol)
		emit_common_procs(ctx, interface)

		emitln(ctx, "%v_interface: %vInterface = {}", interface.name, ctx.wayland_prefix)
		emitln(ctx)
		emit_messages(ctx, protocol, interface.name, "events", interface.events[:])
		emit_messages(ctx, protocol, interface.name, "requests", interface.requests[:])
	}
}

emit_enumerations :: proc(ctx: ^Emit_Context, interface: ^Interface) {
	for enumeration in interface.enumerations {
		emit_comment(ctx, enumeration.description.text, enumeration.description.summary)
		emitln(ctx, "%v_%v :: enum c.int {", interface.name_ada, enumeration.name_ada)
		for entry in enumeration.entries {
			if len(entry.summary) > 0 {
				emit_comment(ctx, entry.summary, indent = 1)
			} else {
				emit_comment(ctx, entry.description.text, entry.description.summary, indent = 1)
			}

			emit(ctx, indent = 1)
			if len(entry.name) > 0 && entry.name[0] >= '0' && entry.name[0] <= '9' {
				emit(ctx, "_")
			}
			emitln(ctx, "%v = %v,", entry.name_ada, entry.value)
		}
		emitln(ctx, "}")
		emitln(ctx)
	}
}

emit_constants :: proc(ctx: ^Emit_Context, interface: ^Interface) {
	emit_since_versions :: proc(
		ctx: ^Emit_Context,
		interface: ^Interface,
		messages: [dynamic]^Message,
	) {
		for message in messages {
			version := message.since if message.since != "" else "1"
			emitln(
				ctx,
				"%v_%v_SINCE_VERSION :: %v",
				interface.name_upper,
				message.name_upper,
				version,
			)
		}
	}

	for request, i in interface.requests {
		emitln(ctx, "%v_%v :: %v", interface.name_upper, request.name_upper, i)
	}
	emitln(ctx)

	emit_since_versions(ctx, interface, interface.requests)
	emit_since_versions(ctx, interface, interface.events)
	emitln(ctx)
}

type_to_odin_type :: proc(ctx: ^Emit_Context, arg: ^Argument) -> string {
	#partial switch arg.type {
	case .New_ID:
		return ""
	case .Int:
		return "i32"
	case .Unsigned:
		return "u32"
	case .Fixed:
		return "Fixed" if ctx.is_wayland_core else "wl.Fixed"
	case .String:
		return "cstring"
	case .Object:
		return "rawptr"
	case .Array:
		return "^Array" if ctx.is_wayland_core else "^wl.Array"
	case .FD:
		return "i32"
	}
	return ""
}

create_argument_text :: proc(ctx: ^Emit_Context, arg: ^Argument) -> string {
	is_return := false
	text := ""

	#partial switch arg.type {
	case .Object:
		if arg.interface_name_ada != "" {
			text = fmt.aprintf("^%v%v", arg.prefix, arg.interface_name_ada)
		} else {
			text = "rawptr"
		}
	case .New_ID:
		if arg.interface_name_ada != "" {
			text = fmt.aprintf("^%v%v", arg.prefix, arg.interface_name_ada)
			is_return = true
		} else {
			text = fmt.aprintf("^%vInterface, version: u32", ctx.wayland_prefix)
		}
	case:
		text = type_to_odin_type(ctx, arg)
	}

	if arg.enumeration_name != "" {
		text = fmt.aprintf("%v%v", arg.enumeration_prefix, arg.enumeration_name_ada)
	}

	if is_return {
		return text
	}
	return fmt.aprintf("%v: %v", arg.name, text)
}

emit_events :: proc(ctx: ^Emit_Context, interface: ^Interface) {
	if len(interface.events) == 0 {
		return
	}

	emitln(ctx, "%v_Listener :: struct {", interface.name_ada)
	for event in interface.events {
		emit_comment(ctx, event.description.text, event.description.summary, indent = 1)
		emit(
			ctx,
			"%v: proc \"c\" (data: rawptr, %v: ^%v",
			event.name,
			interface.name,
			interface.name_ada,
			indent = 1,
		)
		for argument in event.arguments {
			emit(ctx, ", %v", create_argument_text(ctx, argument))
		}
		emit(ctx, ")")

		if event.return_argument != nil {
			emit(ctx, " -> %v", create_argument_text(ctx, event.return_argument))
		}
		emitln(ctx, ",")
	}
	emitln(ctx, "}")
	emitln(ctx)

	emitln(
		ctx,
		"%v_add_listener :: proc \"contextless\" (%v: ^%v, listener: ^%v_Listener, data: rawptr) -> c.int {",
		interface.name,
		interface.name,
		interface.name_ada,
		interface.name_ada,
	)
	emitln(
		ctx,
		"return %vproxy_add_listener(cast(^%vProxy)%v, cast(^proc \"c\" ())listener, data)",
		ctx.wayland_prefix,
		ctx.wayland_prefix,
		interface.name,
		indent = 1,
	)
	emitln(ctx, "}")
	emitln(ctx)
}

emit_requests :: proc(ctx: ^Emit_Context, interface: ^Interface, protocol: ^Protocol) {
	has_destroy := false

	for request in interface.requests {
		has_return := request.return_argument != nil
		has_new_id := request.new_id_argument != nil
		if request.name == "destroy" {
			has_destroy = true
		}

		emit_comment(ctx, request.description.text, request.description.summary)
		emit(
			ctx,
			"%v_%v :: proc \"c\" (%v: ^%v",
			interface.name,
			request.name,
			interface.name,
			interface.name_ada,
		)

		for argument in request.arguments {
			if argument.type == .New_ID {
				if argument.interface_name != "" {
					emit(
						ctx,
						", %v: ^%v%v",
						argument.name,
						argument.prefix,
						argument.interface_name_ada,
					)
				} else {
					emit(
						ctx,
						", %v: ^%vInterface, version: u32",
						argument.name,
						ctx.wayland_prefix,
					)
				}
			} else {
				typ := ""
				if argument.type == .Object {
					if argument.interface_name != "" {
						typ = fmt.aprintf("^%v%v", argument.prefix, argument.interface_name_ada)
					} else {
						typ = "rawptr"
					}
				} else {
					typ = type_to_odin_type(ctx, argument)
				}
				if argument.enumeration_name != "" {
					typ = fmt.aprintf(
						"%v%v",
						argument.enumeration_prefix,
						argument.enumeration_name_ada,
					)
				}
				emit(ctx, ", %v: %v", argument.name, typ)
			}
		}
		emit(ctx, ")")

		if has_return {
			if request.return_argument.interface_name_ada != "" {
				emit(
					ctx,
					" -> ^%v%v",
					request.return_argument.prefix,
					request.return_argument.interface_name_ada,
				)
			} else {
				emit(ctx, " -> rawptr")
			}
		} else if has_new_id {
			emit(ctx, " -> rawptr")
		}
		emitln(ctx, " {")

		if has_return || has_new_id {
			emit(
				ctx,
				"ret := %vproxy_marshal_flags(cast(^%vProxy)%v, %v_%v",
				ctx.wayland_prefix,
				ctx.wayland_prefix,
				interface.name,
				interface.name_upper,
				request.name_upper,
				indent = 1,
			)

			if has_return {
				emit(
					ctx,
					", &%v%v_interface, %vproxy_get_version(cast(^%vProxy)%v)",
					request.return_argument.prefix,
					request.return_argument.interface_name,
					ctx.wayland_prefix,
					ctx.wayland_prefix,
					interface.name,
				)
			} else if has_new_id {
				emit(ctx, ", %v, version", request.new_id_argument.name)
			} else {
				emit(
					ctx,
					", nil, %vproxy_get_version(cast(^%vProxy)%v)",
					ctx.wayland_prefix,
					ctx.wayland_prefix,
					interface.name,
				)
			}

			if request.destructor {
				emit(ctx, ", %vMARSHAL_FLAG_DESTROY", ctx.wayland_prefix)
			} else {
				emit(ctx, ", 0")
			}

			if has_return {
				emit(ctx, ", nil")
			}

			for argument in request.arguments {
				if argument.type == .New_ID {
					if argument.interface_name == "" {
						emit(ctx, ", %v.name, version, nil", argument.name)
					} else {
						emit(ctx, ", nil")
					}
				} else {
					emit(ctx, ", %v", argument.name)
				}
			}
			emitln(ctx, ")")

			if has_return && request.return_argument.interface_name_ada != "" {
				emitln(
					ctx,
					"return cast(^%v%v)ret",
					request.return_argument.prefix,
					request.return_argument.interface_name_ada,
					indent = 1,
				)
			} else {
				emitln(ctx, "return cast(rawptr)ret", indent = 1)
			}
		} else {
			emit(
				ctx,
				"%vproxy_marshal_flags(cast(^%vProxy)%v, %v_%v, nil, %vproxy_get_version(cast(^%vProxy)%v)",
				ctx.wayland_prefix,
				ctx.wayland_prefix,
				interface.name,
				interface.name_upper,
				request.name_upper,
				ctx.wayland_prefix,
				ctx.wayland_prefix,
				interface.name,
				indent = 1,
			)

			if request.destructor {
				emit(ctx, ", %vMARSHAL_FLAG_DESTROY", ctx.wayland_prefix)
			} else {
				emit(ctx, ", 0")
			}

			for argument in request.arguments {
				emit(ctx, ", %v", argument.name)
			}
			emitln(ctx, ")")
		}

		emitln(ctx, "}")
		emitln(ctx)
	}

	if !has_destroy && !(protocol.name == "wayland" && interface.name == "display") {
		emitln(
			ctx,
			"%v_destroy :: proc \"c\" (%v: ^%v) {",
			interface.name,
			interface.name,
			interface.name_ada,
		)
		emitln(
			ctx,
			"%vproxy_destroy(cast(^%vProxy)%v)",
			ctx.wayland_prefix,
			ctx.wayland_prefix,
			interface.name,
			indent = 1,
		)
		emitln(ctx, "}")
		emitln(ctx)
	}
}

argument_type_signature_char :: proc(arg_type: Argument_Type) -> rune {
	#partial switch arg_type {
	case .New_ID:
		return 'n'
	case .Int:
		return 'i'
	case .Unsigned:
		return 'u'
	case .Fixed:
		return 'f'
	case .String:
		return 's'
	case .Object:
		return 'o'
	case .Array:
		return 'a'
	case .FD:
		return 'h'
	}
	return 'i'
}

emit_messages :: proc(
	ctx: ^Emit_Context,
	protocol: ^Protocol,
	name: string,
	suffix: string,
	messages: []^Message,
) {
	emitln(ctx, "%v_%v: []%vMessage = {", name, suffix, ctx.wayland_prefix)
	for message in messages {
		emit(ctx, "{\"%v\", \"%v", message.name, message.since, indent = 1)

		if message.return_argument != nil {
			emit(ctx, "n")
		}

		for argument in message.arguments {
			if argument.nullable {
				emit(ctx, "?")
			}
			if argument.type == .New_ID && argument.interface_name == "" {
				emit(ctx, "su")
			}
			emit(ctx, "%v", argument_type_signature_char(argument.type))
		}

		emitln(ctx, "\", raw_data(%v_types)[%v:]},", protocol.name, message.type_index)
	}
	emitln(ctx, "}")
	emitln(ctx)
}

emit_common_procs :: proc(ctx: ^Emit_Context, interface: ^Interface) {
	emitln(
		ctx,
		"%v_get_version :: proc \"contextless\" (%v: ^%v) -> u32 {",
		interface.name,
		interface.name,
		interface.name_ada,
	)
	emitln(
		ctx,
		"return %vproxy_get_version(cast(^%vProxy)%v)",
		ctx.wayland_prefix,
		ctx.wayland_prefix,
		interface.name,
		indent = 1,
	)
	emitln(ctx, "}")
	emitln(ctx)

	emitln(
		ctx,
		"%v_get_user_data :: proc \"contextless\" (%v: ^%v) -> rawptr {",
		interface.name,
		interface.name,
		interface.name_ada,
	)
	emitln(
		ctx,
		"return %vproxy_get_user_data(cast(^%vProxy)%v)",
		ctx.wayland_prefix,
		ctx.wayland_prefix,
		interface.name,
		indent = 1,
	)
	emitln(ctx, "}")
	emitln(ctx)

	emitln(
		ctx,
		"%v_set_user_data :: proc \"contextless\" (%v: ^%v, user_data: rawptr) {",
		interface.name,
		interface.name,
		interface.name_ada,
	)
	emitln(
		ctx,
		"%vproxy_set_user_data(cast(^%vProxy)%v, user_data)",
		ctx.wayland_prefix,
		ctx.wayland_prefix,
		interface.name,
		indent = 1,
	)
	emitln(ctx, "}")
	emitln(ctx)
}

CORE_WAYLAND :: `
foreign import wayland_client "system:wayland-client"
import "core:c"

MARSHAL_FLAG_DESTROY :: 1 << 0

Dispatcher_Func :: proc "c" (impl: rawptr, target: rawptr, opcode: u32, msg: ^Message, args: [^]Argument) -> c.int
Fixed :: i32

Argument :: struct #raw_union {
	i: i32,
	u: u32,
	f: Fixed,
	s: cstring,
	o: rawptr,
	n: u32,
	a: ^Array,
	h: i32,
}

Array :: struct {
	size: c.size_t,
	alloc: c.size_t,
	data: rawptr,
}

Message :: struct {
	name: cstring,
	signature: cstring,
	types: [^]^Interface,
}

Interface :: struct {
	name: cstring,
	version: c.int,
	method_count: c.int,
	methods: [^]Message,
	event_count: c.int,
	events: [^]Message,
}

Event_Queue :: struct {}
Object :: struct {}
Proxy :: struct {}

@(default_calling_convention="c", link_prefix="wl_")
foreign wayland_client {
	display_connect                 :: proc(name: cstring) -> ^Display ---
	display_connect_to_fd           :: proc(fd: c.int) -> ^Display ---
	display_disconnect              :: proc(display: ^Display) ---
	display_get_fd                  :: proc(display: ^Display) -> c.int ---
	display_dispatch                :: proc(display: ^Display) -> c.int ---
	display_dispatch_queue          :: proc(display: ^Display, queue: ^Event_Queue) -> c.int ---
	display_dispatch_queue_pending  :: proc(display: ^Display, queue: ^Event_Queue) -> c.int ---
	display_dispatch_pending        :: proc(display: ^Display) -> c.int ---
	display_get_error               :: proc(display: ^Display) -> c.int ---
	display_get_protocol_error      :: proc(display: ^Display, interface: ^Interface, id: ^u32) -> u32 ---
	display_flush                   :: proc(display: ^Display) -> c.int ---
	display_roundtrip_queue         :: proc(display: ^Display, queue: ^Event_Queue) -> c.int ---
	display_roundtrip               :: proc(display: ^Display) -> c.int ---
	display_create_queue            :: proc(display: ^Display) -> ^Event_Queue ---
	display_create_queue_with_name  :: proc(display: ^Display, name: cstring) -> ^Event_Queue ---
	display_prepare_read_queue      :: proc(display: ^Display, queue: ^Event_Queue) -> c.int ---
	display_prepare_read            :: proc(display: ^Display) -> c.int ---
	display_cancel_read             :: proc(display: ^Display) ---
	display_read_events             :: proc(display: ^Display) -> c.int ---
	display_set_max_buffer_size     :: proc(display: ^Display, max_buffer_size: c.size_t) ---

	event_queue_destroy             :: proc(queue: ^Event_Queue) ---
	event_queue_get_name            :: proc(queue: ^Event_Queue) -> cstring ---

	proxy_create                    :: proc(factory: ^Proxy, interface: ^Interface) -> ^Proxy ---
	proxy_create_wrapper            :: proc(proxy: rawptr) -> rawptr ---
	proxy_wrapper_destroy           :: proc(proxy_wrapper: rawptr) ---
	proxy_destroy                   :: proc(proxy: ^Proxy) ---
	proxy_add_listener              :: proc(proxy: ^Proxy, implementation: ^proc "c" (), data: rawptr) -> c.int ---
	proxy_get_listener              :: proc(proxy: ^Proxy) -> rawptr ---
	proxy_add_dispatcher            :: proc(proxy: ^Proxy, dispatcher_func: Dispatcher_Func, dispatcher_data: rawptr, data: rawptr) -> c.int ---
	proxy_set_user_data             :: proc(proxy: ^Proxy, user_data: rawptr) ---
	proxy_get_user_data             :: proc(proxy: ^Proxy) -> rawptr ---
	proxy_get_version               :: proc(proxy: ^Proxy) -> u32 ---
	proxy_get_id                    :: proc(proxy: ^Proxy) -> u32 ---
	proxy_set_tag                   :: proc(proxy: ^Proxy, tag: ^u8) ---
	proxy_get_tag                   :: proc(proxy: ^Proxy) -> ^u8 ---
	proxy_get_class                 :: proc(proxy: ^Proxy) -> cstring ---
	proxy_get_display               :: proc(proxy: ^Proxy) -> ^Display ---
	proxy_set_queue                 :: proc(proxy: ^Proxy, queue: ^Event_Queue) ---
	proxy_get_queue                 :: proc(proxy: ^Proxy) -> ^Event_Queue ---

	proxy_marshal_flags                       :: proc(proxy: ^Proxy, opcode: u32, interface: ^Interface, version: u32, flags: u32, #c_vararg args: ..any) -> ^Proxy ---
	proxy_marshal_array_flags                 :: proc(proxy: ^Proxy, opcode: u32, interface: ^Interface, version: u32, flags: u32, args: ^Argument) -> ^Proxy ---
	proxy_marshal                             :: proc(proxy: ^Proxy, opcode: u32, #c_vararg args: ..any) -> ^Proxy ---
	proxy_marshal_array                       :: proc(proxy: ^Proxy, opcode: u32, args: ^Argument) ---
	proxy_marshal_constructor                 :: proc(proxy: ^Proxy, opcode: u32, interface: ^Interface, #c_vararg args: ..any) -> ^Proxy ---
	proxy_marshal_constructor_versioned       :: proc(proxy: ^Proxy, opcode: u32, interface: ^Interface, version: u32, #c_vararg args: ..any) -> ^Proxy ---
	proxy_marshal_array_constructor           :: proc(proxy: ^Proxy, opcode: u32, args: ^Argument, interface: ^Interface) -> ^Proxy ---
	proxy_marshal_array_constructor_versioned :: proc(proxy: ^Proxy, opcode: u32, args: ^Argument, interface: ^Interface, version: u32) -> ^Proxy ---
}`

get_attribute_required :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	attribute: string,
) -> (
	value: string,
	ok: bool,
) {
	found_value, found := xml.find_attribute_val_by_key(doc, id, attribute)
	if !found {
		fmt.eprintfln(
			"Missing required attribute '%v' on <%v>.",
			attribute,
			doc.elements[id].ident,
		)
		return "", false
	}
	return found_value, true
}

get_attribute_optional :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	attribute: string,
) -> string {
	value, found := xml.find_attribute_val_by_key(doc, id, attribute)
	if !found {
		return ""
	}
	return value
}

get_attribute_optional_bool :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	attribute: string,
) -> (
	value: bool,
	ok: bool,
) {
	raw, found := xml.find_attribute_val_by_key(doc, id, attribute)
	if !found {
		return false, true
	}

	switch raw {
	case "true":
		return true, true
	case "false":
		return false, true
	case:
		fmt.eprintfln(
			"Invalid boolean value '%v' for attribute '%v' on <%v>. Expected true/false.",
			raw,
			attribute,
			doc.elements[id].ident,
		)
		return false, false
	}
}

element_text :: proc(doc: ^xml.Document, id: xml.Element_ID) -> string {
	parts: [dynamic]string
	defer delete(parts)

	for value in doc.elements[id].value {
		switch text in value {
		case string:
			if len(text) > 0 {
				append(&parts, text)
			}
		case xml.Element_ID:
			continue
		}
	}

	switch len(parts) {
	case 0:
		return ""
	case 1:
		return parts[0]
	case:
		return strings.concatenate(parts[:])
	}
}

parse_description :: proc(
	doc: ^xml.Document,
	parent_id: xml.Element_ID,
) -> (
	description: Description,
	ok: bool,
) {
	description_id, found := xml.find_child_by_ident(doc, parent_id, "description")
	if !found {
		return Description{}, true
	}

	description.summary = get_attribute_required(doc, description_id, "summary") or_return

	description.text = element_text(doc, description_id)
	return description, true
}

parse_interface :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
) -> (
	interface: ^Interface,
	ok: bool,
) {
	interface = new(Interface)

	interface.full_name = get_attribute_required(doc, id, "name") or_return

	interface.name = short_interface_name(interface.full_name)
	interface.name_ada = strings.to_ada_case(interface.name)
	interface.name_upper = strings.to_upper(interface.name)
	interface.version = get_attribute_required(doc, id, "version") or_return

	interface.description = parse_description(doc, id) or_return

	for value in doc.elements[id].value {
		switch child_id in value {
		case string:
			continue
		case xml.Element_ID:
			child := doc.elements[child_id]
			if child.kind != .Element {
				continue
			}

			switch child.ident {
			case "description":
				continue
			case "enum":
				enumeration := parse_enumeration(doc, child_id) or_return
				append(&interface.enumerations, enumeration)
			case "request":
				request := parse_message(doc, child_id, interface) or_return
				append(&interface.requests, request)
			case "event":
				event := parse_message(doc, child_id, interface) or_return
				append(&interface.events, event)
			case:
				continue
			}
		}
	}

	return interface, true
}

parse_enumeration :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
) -> (
	enumeration: ^Enumeration,
	ok: bool,
) {
	enumeration = new(Enumeration)

	enumeration.name = get_attribute_required(doc, id, "name") or_return

	enumeration.name_ada = strings.to_ada_case(enumeration.name)
	enumeration.since = get_attribute_optional(doc, id, "since")
	enumeration.bitfield = get_attribute_optional_bool(doc, id, "bitfield") or_return
	enumeration.description = parse_description(doc, id) or_return

	for value in doc.elements[id].value {
		switch child_id in value {
		case string:
			continue
		case xml.Element_ID:
			child := doc.elements[child_id]
			if child.kind != .Element || child.ident != "entry" {
				continue
			}

			entry: Enumeration_Entry
			entry.name = get_attribute_required(doc, child_id, "name") or_return
			entry.value = get_attribute_required(doc, child_id, "value") or_return

			entry.name_ada = strings.to_ada_case(entry.name)
			entry.name_upper = strings.to_upper(entry.name)
			entry.summary = get_attribute_optional(doc, child_id, "summary")
			entry.since = get_attribute_optional(doc, child_id, "since")
			entry.deprecated_since = get_attribute_optional(doc, child_id, "deprecated-since")
			entry.description = parse_description(doc, child_id) or_return

			append(&enumeration.entries, entry)
		}
	}

	if len(enumeration.entries) == 0 {
		fmt.eprintfln("Enumeration '%v' is empty.", enumeration.name)
		return
	}

	return enumeration, true
}

parse_message :: proc(
	doc: ^xml.Document,
	id: xml.Element_ID,
	interface: ^Interface,
) -> (
	message: ^Message,
	ok: bool,
) {
	message = new(Message)

	message.name = get_attribute_required(doc, id, "name") or_return

	message.name_upper = strings.to_upper(message.name)
	message.destructor = get_attribute_optional(doc, id, "type") == "destructor"
	message.since = get_attribute_optional(doc, id, "since")
	message.deprecated_since = get_attribute_optional(doc, id, "deprecated-since")
	message.description = parse_description(doc, id) or_return

	for value in doc.elements[id].value {
		switch child_id in value {
		case string:
			continue
		case xml.Element_ID:
			child := doc.elements[child_id]
			if child.kind != .Element || child.ident != "arg" {
				continue
			}

			argument := parse_argument(doc, child_id) or_return

			if argument.type == .New_ID && argument.interface_name != "" {
				if message.return_argument != nil {
					fmt.eprintfln(
						"Message '%v.%v' has multiple typed new_id arguments.",
						interface.full_name,
						message.name,
					)
					return
				}
				message.return_argument = argument
				continue
			}

			if argument.type == .New_ID && message.new_id_argument == nil {
				message.new_id_argument = argument
			}

			append(&message.arguments, argument)
		}
	}

	if message.name == "destroy" && !message.destructor {
		fmt.eprintfln(
			"Request '%v.destroy' must be marked as type='destructor'.",
			interface.full_name,
		)
		return
	}

	return message, true
}

parse_argument :: proc(doc: ^xml.Document, id: xml.Element_ID) -> (argument: ^Argument, ok: bool) {
	argument = new(Argument)

	argument.name = get_attribute_required(doc, id, "name") or_return

	raw_type := get_attribute_required(doc, id, "type") or_return
	argument.type = string_to_argument_type(raw_type) or_return

	argument.nullable = get_attribute_optional_bool(doc, id, "allow-null") or_return
	if argument.nullable && !is_nullable_argument_type(argument.type) {
		fmt.eprintfln(
			"allow-null is only valid for object, string, and array arguments. Found on '%v'.",
			argument.name,
		)
		return
	}

	argument.interface_name = get_attribute_optional(doc, id, "interface")
	if argument.interface_name != "" && argument.type != .Object && argument.type != .New_ID {
		fmt.eprintfln(
			"Argument '%v' uses interface='%v', but type '%v' cannot reference interfaces.",
			argument.name,
			argument.interface_name,
			raw_type,
		)
		return
	}

	argument.enumeration_name = get_attribute_optional(doc, id, "enum")
	argument.summary = get_attribute_optional(doc, id, "summary")
	return argument, true
}

string_to_argument_type :: proc(raw: string) -> (type: Argument_Type, ok: bool) {
	switch raw {
	case "new_id":
		return .New_ID, true
	case "int":
		return .Int, true
	case "uint":
		return .Unsigned, true
	case "fixed":
		return .Fixed, true
	case "string":
		return .String, true
	case "object":
		return .Object, true
	case "array":
		return .Array, true
	case "fd":
		return .FD, true
	case:
		fmt.eprintfln("Unknown argument type '%v'.", raw)
		return .Int, false
	}
}

is_nullable_argument_type :: proc(arg_type: Argument_Type) -> bool {
	#partial switch arg_type {
	case .String, .Object, .Array:
		return true
	case:
		return false
	}
}

short_interface_name :: proc(full_name: string) -> string {
	index := strings.index_byte(full_name, '_')
	if index <= 0 || index + 1 >= len(full_name) {
		return full_name
	}
	return full_name[index + 1:]
}

find_interface_by_full_name :: proc(protocol: ^Protocol, full_name: string) -> ^Interface {
	for interface in protocol.interfaces {
		if interface.full_name == full_name {
			return interface
		}
	}
	return nil
}

find_enumeration_by_name :: proc(interface: ^Interface, name: string) -> ^Enumeration {
	for enumeration in interface.enumerations {
		if enumeration.name == name {
			return enumeration
		}
	}
	return nil
}

resolve_interface_reference :: proc(
	protocol: ^Protocol,
	interface_name: string,
) -> (
	prefix, short_name: string,
) {
	target := find_interface_by_full_name(protocol, interface_name)
	if target != nil {
		return "", target.name
	}

	if strings.has_prefix(interface_name, "wl_") {
		return "wl.", short_interface_name(interface_name)
	}

	return "", short_interface_name(interface_name)
}

resolve_enumeration_reference :: proc(
	protocol: ^Protocol,
	current_interface: ^Interface,
	enum_reference: string,
) -> (
	prefix: string,
	resolved_name: string,
	bitfield, found: bool,
) {
	dot_index := strings.last_index_byte(enum_reference, '.')
	if dot_index > 0 && dot_index + 1 < len(enum_reference) {
		target_interface_name := enum_reference[:dot_index]
		enum_name := enum_reference[dot_index + 1:]
		target_interface := find_interface_by_full_name(protocol, target_interface_name)

		if target_interface == nil {
			if strings.has_prefix(target_interface_name, "wl_") {
				return "wl.",
					fmt.aprintf("%v_%v", short_interface_name(target_interface_name), enum_name),
					false,
					false
			}

			// Best-effort normalization for non-local enum references.
			return "",
				fmt.aprintf("%v_%v", short_interface_name(target_interface_name), enum_name),
				false,
				false
		}

		resolved_name = fmt.aprintf("%v_%v", target_interface.name, enum_name)
		enumeration := find_enumeration_by_name(target_interface, enum_name)
		if enumeration != nil {
			return "", resolved_name, enumeration.bitfield, true
		}
		return "", resolved_name, false, false
	}

	resolved_name = fmt.aprintf("%v_%v", current_interface.name, enum_reference)
	enumeration := find_enumeration_by_name(current_interface, enum_reference)
	if enumeration != nil {
		return "", resolved_name, enumeration.bitfield, true
	}
	return "", resolved_name, false, false
}

normalize_argument :: proc(
	protocol: ^Protocol,
	interface: ^Interface,
	argument: ^Argument,
) -> (
	ok: bool,
) {
	if argument.interface_name != "" {
		argument.prefix, argument.interface_name = resolve_interface_reference(
			protocol,
			argument.interface_name,
		)
		argument.interface_name_ada = strings.to_ada_case(argument.interface_name)
	}

	if argument.enumeration_name == "" {
		return true
	}

	if argument.type != .Int && argument.type != .Unsigned {
		fmt.eprintfln(
			"Argument '%v' in '%v' references enum '%v' but has incompatible type.",
			argument.name,
			interface.full_name,
			argument.enumeration_name,
		)
		return false
	}

	enum_prefix, resolved_name, bitfield, found := resolve_enumeration_reference(
		protocol,
		interface,
		argument.enumeration_name,
	)

	if found && bitfield && argument.type != .Unsigned {
		fmt.eprintfln(
			"Argument '%v' in '%v' references bitfield enum '%v' but is not uint.",
			argument.name,
			interface.full_name,
			argument.enumeration_name,
		)
		return false
	}

	argument.enumeration_prefix = enum_prefix
	argument.enumeration_name = resolved_name
	argument.enumeration_name_ada = strings.to_ada_case(resolved_name)
	return true
}

normalize_message :: proc(
	protocol: ^Protocol,
	interface: ^Interface,
	message: ^Message,
) -> (
	ok: bool,
) {
	message.all_null = true

	if message.return_argument != nil {
		normalize_argument(protocol, interface, message.return_argument) or_return
		if message.return_argument.interface_name != "" {
			message.all_null = false
		}
	}

	for argument in message.arguments {
		normalize_argument(protocol, interface, argument) or_return

		if (argument.type == .New_ID || argument.type == .Object) &&
		   argument.interface_name != "" {
			message.all_null = false
		}
	}

	if message.all_null && len(message.arguments) > protocol.null_run_length {
		protocol.null_run_length = len(message.arguments)
	}

	return true
}

finalize_protocol :: proc(protocol: ^Protocol) -> bool {
	protocol.null_run_length = 0
	protocol.type_index_counter = 0

	for interface in protocol.interfaces {
		for request in interface.requests {
			normalize_message(protocol, interface, request) or_return
		}
		for event in interface.events {
			normalize_message(protocol, interface, event) or_return
		}
	}

	return true
}
