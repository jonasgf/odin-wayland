package scanner

import "base:runtime"
import "core:encoding/xml"
import "core:flags"
import "core:fmt"
import os "core:os/os2"
import "core:path/filepath"
import "core:slice"
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
	name_odin:            string,
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
	name:                string,
	copyright:           string,
	description:         Description,
	interfaces:          [dynamic]^Interface,
	external_imports:    map[string]string,
	wayland_import_path: string,
	null_run_length:     int,
	type_index_counter:  int,
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

Registry_Source :: struct {
	xml_path:    string,
	import_path: string,
}

Protocol_Metadata :: struct {
	name:               string,
	xml_path:           string,
	import_path:        string,
	module_name:        string,
	alias:              string,
	interface_names:    [dynamic]string,
	imported_protocols: [dynamic]string,
}

Interface_Owner :: struct {
	full_interface_name: string,
	protocol_name:       string,
	import_path:         string,
	module_name:         string,
	alias:               string,
	short_name:          string,
	xml_path:            string,
}

Interface_Registry :: struct {
	owners:            map[string][dynamic]Interface_Owner,
	protocols_by_path: map[string]Protocol_Metadata,
}

Resolution_Context :: struct {
	protocol_name:      string,
	import_path:        string,
	module_name:        string,
	imported_protocols: []string,
}

Reference_Source :: struct {
	protocol_name:        string,
	interface_full_name:  string,
	message_name:         string,
	argument_name:        string,
	referenced_interface: string,
}

Scanner_Options :: struct {
	output_dir:    string `args:"name=output-dir" usage:"Output directory for generated bindings."`,
	wayland_xml:   string `args:"name=wayland-xml" usage:"Path to wayland.xml."`,
	protocols_dir: string `args:"name=protocols-dir" usage:"Path to wayland-protocols root."`,
}

DEFAULT_OUTPUT_DIR :: "wayland"
DEFAULT_WAYLAND_XML_PATH :: "/usr/share/wayland/wayland.xml"
DEFAULT_WAYLAND_PROTOCOLS_DIR :: "/usr/share/wayland-protocols"

main :: proc() {
	options: Scanner_Options
	flags.parse_or_exit(&options, os.args)

	if options.output_dir == "" {
		options.output_dir = DEFAULT_OUTPUT_DIR
	}
	if options.wayland_xml == "" {
		options.wayland_xml = DEFAULT_WAYLAND_XML_PATH
	}
	if options.protocols_dir == "" {
		options.protocols_dir = DEFAULT_WAYLAND_PROTOCOLS_DIR
	}

	if !generate_all_protocols(&options) {
		os.exit(1)
	}
}

Generation_Target :: struct {
	source:      Registry_Source,
	output_file: string,
}

generate_all_protocols :: proc(options: ^Scanner_Options) -> bool {
	registry_xml: [dynamic]string
	append(&registry_xml, options.wayland_xml)
	registry_sources, sources_ok := collect_registry_sources(
		registry_xml[:],
		[]string{options.protocols_dir},
	)
	if !sources_ok {
		return false
	}

	interface_registry, registry_ok := build_interface_registry(registry_sources[:])
	if !registry_ok {
		return false
	}

	targets, targets_ok := build_generation_targets(
		registry_sources[:],
		options.output_dir,
		options.wayland_xml,
		options.protocols_dir,
	)
	if !targets_ok {
		return false
	}

	for target in targets {
		doc, protocol, protocol_ok := parse_protocol_file(target.source.xml_path)
		if !protocol_ok {
			return false
		}

		if !finalize_protocol(protocol, &interface_registry, target.source.xml_path) {
			xml.destroy(doc)
			return false
		}

		fmt.printfln("%v", target.source.xml_path)
		if !emit_protocol_to_file(target.output_file, protocol, protocol.name) {
			xml.destroy(doc)
			return false
		}
		xml.destroy(doc)
	}

	return true
}

build_generation_targets :: proc(
	sources: []Registry_Source,
	output_dir: string,
	wayland_xml: string,
	protocols_dir: string,
) -> (
	targets: [dynamic]Generation_Target,
	ok: bool,
) {
	abs_wayland_xml, wayland_err := os.get_absolute_path(wayland_xml, context.temp_allocator)
	if wayland_err != nil {
		fmt.eprintfln("Failed to resolve wayland XML path '%v': %v", wayland_xml, wayland_err)
		return
	}

	abs_protocols_dir, protocols_err := os.get_absolute_path(protocols_dir, context.temp_allocator)
	if protocols_err != nil {
		fmt.eprintfln(
			"Failed to resolve protocols directory '%v': %v",
			protocols_dir,
			protocols_err,
		)
		return
	}

	for source in sources {
		target := Generation_Target {
			source = source,
		}

		if source.xml_path == abs_wayland_xml {
			target.output_file = fmt.aprintf("%v/wayland.odin", output_dir)
		} else {
			relative, relative_err := os.get_relative_path(
				abs_protocols_dir,
				source.xml_path,
				context.temp_allocator,
			)
			if relative_err != nil {
				fmt.eprintfln(
					"Registry source '%v' is not under protocols directory '%v': %v",
					source.xml_path,
					abs_protocols_dir,
					relative_err,
				)
				return
			}

			relative, _ = strings.replace_all(relative, ".xml", ".odin")
			target.output_file = fmt.aprintf("%v/%v", output_dir, relative)
		}

		append(&targets, target)
	}

	return targets, true
}

parse_protocol_file :: proc(path: string) -> (doc: ^xml.Document, protocol: ^Protocol, ok: bool) {
	loaded_doc, xml_err := xml.load_from_file(path)
	if xml_err != .None {
		fmt.eprintfln("Failed to load XML file '%v': %v", path, xml_err)
		return
	}
	doc = loaded_doc

	protocol, ok = parse_protocol(doc)
	if !ok {
		fmt.eprintfln("Failed to parse protocol from '%v'.", path)
		xml.destroy(doc)
		return nil, nil, false
	}
	return doc, protocol, true
}

emit_protocol_to_file :: proc(path: string, protocol: ^Protocol, package_name: string) -> bool {
	dir_path, _ := os.split_path(path)
	if dir_path != "" && dir_path != "." {
		if mk_err := os.make_directory_all(dir_path, 0o755); mk_err != nil {
			if mk_err != .Exist {
				fmt.eprintfln("Failed to create output directory '%v': %v", dir_path, mk_err)
				return false
			}
		}
	}

	output_file, open_err := os.open(path, {.Create, .Trunc, .Write}, os.Permissions_Default_File)
	if open_err != nil {
		fmt.eprintfln("Failed to open output file '%v': %v", path, open_err)
		return false
	}
	defer os.close(output_file)

	emit_protocol(output_file, protocol, package_name)
	return true
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

	return protocol, true
}

collect_registry_sources :: proc(
	registry_xml: []string,
	registry_dir: []string,
) -> (
	sources: [dynamic]Registry_Source,
	ok: bool,
) {
	source_index := make(map[string]int)

	for xml_path in registry_xml {
		abs_path, abs_err := os.get_absolute_path(xml_path, context.temp_allocator)
		if abs_err != nil {
			fmt.eprintfln("Failed to resolve registry XML path '%v': %v", xml_path, abs_err)
			return
		}

		path_clone, path_ok := clone_string_or_report(abs_path, "registry XML path")
		if !path_ok {
			return
		}
		import_path := derive_import_path_for_registry_xml(abs_path)
		import_clone, import_ok := clone_string_or_report(import_path, "registry import path")
		if !import_ok {
			return
		}

		add_registry_source(&sources, &source_index, path_clone, import_clone) or_return
	}

	for dir_path in registry_dir {
		dir_sources, dir_ok := collect_xml_files_from_directory(dir_path)
		if !dir_ok {
			return
		}

		for source in dir_sources {
			add_registry_source(
				&sources,
				&source_index,
				source.xml_path,
				source.import_path,
			) or_return
		}
	}

	sort_registry_source :: proc(a, b: Registry_Source) -> slice.Ordering {
		if a.xml_path != b.xml_path {
			return slice.cmp(a.xml_path, b.xml_path)
		}
		return slice.cmp(a.import_path, b.import_path)
	}

	slice.sort_by_cmp(sources[:], sort_registry_source)

	return sources, true
}

add_registry_source :: proc(
	sources: ^[dynamic]Registry_Source,
	source_index: ^map[string]int,
	xml_path: string,
	import_path: string,
) -> bool {
	if existing_index, exists := source_index^[xml_path]; exists {
		existing := sources^[existing_index]
		if existing.import_path != "" && import_path != "" && existing.import_path != import_path {
			fmt.eprintfln(
				"Conflicting import paths for registry XML '%v': '%v' vs '%v'.",
				xml_path,
				existing.import_path,
				import_path,
			)
			return false
		}
		if existing.import_path == "" && import_path != "" {
			sources^[existing_index].import_path = import_path
		}
		return true
	}

	append(sources, Registry_Source{xml_path = xml_path, import_path = import_path})
	source_index^[xml_path] = len(sources^) - 1
	return true
}

collect_xml_files_from_directory :: proc(
	dir_path: string,
) -> (
	sources: [dynamic]Registry_Source,
	ok: bool,
) {
	abs_dir, abs_err := os.get_absolute_path(dir_path, context.temp_allocator)
	if abs_err != nil {
		fmt.eprintfln("Failed to resolve registry directory '%v': %v", dir_path, abs_err)
		return
	}

	walker := os.walker_create(abs_dir)
	defer os.walker_destroy(&walker)

	for info in os.walker_walk(&walker) {
		if path, err := os.walker_error(&walker); err != nil {
			fmt.eprintfln("Failed while scanning registry directory '%v': %v", path, err)
			return
		}
		if info.type != .Regular || !strings.has_suffix(info.name, ".xml") {
			continue
		}

		relative_path, relative_err := os.get_relative_path(
			abs_dir,
			info.fullpath,
			context.temp_allocator,
		)
		if relative_err != nil {
			fmt.eprintfln(
				"Failed to compute relative path for '%v' in registry directory '%v': %v",
				info.fullpath,
				abs_dir,
				relative_err,
			)
			return
		}

		xml_clone, xml_ok := clone_string_or_report(info.fullpath, "registry XML path")
		if !xml_ok {
			return
		}
		import_path := import_path_from_registry_relative(relative_path)
		import_clone, import_ok := clone_string_or_report(import_path, "registry import path")
		if !import_ok {
			return
		}

		append(&sources, Registry_Source{xml_path = xml_clone, import_path = import_clone})
	}

	if path, err := os.walker_error(&walker); err != nil {
		fmt.eprintfln("Failed while scanning registry directory '%v': %v", path, err)
		return
	}

	return sources, true
}

import_path_from_registry_relative :: proc(relative_path: string) -> string {
	clean_relative := normalize_import_segment(relative_path)
	dir, _ := os.split_path(clean_relative)
	if dir == "" || dir == "." {
		return ""
	}
	if dir[len(dir) - 1] == '/' {
		dir = dir[:len(dir) - 1]
	}
	return dir
}

derive_import_path_for_registry_xml :: proc(xml_path: string) -> string {
	clean_path := normalize_import_segment(xml_path)
	_, file_name := os.split_path(clean_path)
	if file_name == "wayland.xml" {
		return ""
	}

	protocol_class_paths := [3]string{"/stable/", "/staging/", "/unstable/"}
	for class_path in protocol_class_paths {
		start := strings.index(clean_path, class_path)
		if start >= 0 {
			relative := clean_path[start + 1:]
			return import_path_from_registry_relative(relative)
		}
	}

	if strings.has_prefix(clean_path, "stable/") ||
	   strings.has_prefix(clean_path, "staging/") ||
	   strings.has_prefix(clean_path, "unstable/") {
		return import_path_from_registry_relative(clean_path)
	}

	return ""
}

relative_import_path :: proc(
	current_import_path: string,
	target_import_path: string,
) -> (
	relative_path: string,
	ok: bool,
) {
	base_os, base_new := filepath.from_slash(current_import_path)
	if base_new {
		defer delete(base_os)
	}

	target_os, target_new := filepath.from_slash(target_import_path)
	if target_new {
		defer delete(target_os)
	}

	rel_os, rel_err := filepath.rel(base_os, target_os)
	if rel_err != .None {
		fmt.eprintfln(
			"Failed to compute relative import path from '%v' to '%v': %v",
			current_import_path,
			target_import_path,
			rel_err,
		)
		return
	}
	defer delete(rel_os)

	rel_slash, rel_slash_new := filepath.to_slash(rel_os)
	if rel_slash_new {
		defer delete(rel_slash)
	}

	normalized := rel_slash
	if strings.has_suffix(normalized, "/.") && len(normalized) > 2 {
		normalized = normalized[:len(normalized) - 2]
	}
	if normalized == "" {
		normalized = "."
	}

	relative_path, ok = clone_string_or_report(normalized, "relative import path")
	return
}

normalize_import_segment :: proc(raw: string) -> string {
	normalized := raw
	if strings.contains_rune(normalized, '\\') {
		normalized, _ = strings.replace_all(normalized, "\\", "/")
	}
	return normalized
}

clone_string_or_report :: proc(raw: string, label: string) -> (cloned: string, ok: bool) {
	alloc_err: runtime.Allocator_Error
	cloned, alloc_err = strings.clone(raw)
	if alloc_err != nil {
		fmt.eprintfln("Failed to allocate %v: %v", label, alloc_err)
		return "", false
	}
	return cloned, true
}

build_interface_registry :: proc(
	sources: []Registry_Source,
) -> (
	registry: Interface_Registry,
	ok: bool,
) {
	registry.owners = make(map[string][dynamic]Interface_Owner)
	registry.protocols_by_path = make(map[string]Protocol_Metadata)
	if len(sources) == 0 {
		return registry, true
	}

	protocols: [dynamic]Protocol_Metadata
	for source in sources {
		metadata, metadata_ok := parse_protocol_metadata_from_source(source)
		if !metadata_ok {
			return
		}
		append(&protocols, metadata)
	}

	assign_protocol_aliases(protocols[:]) or_return

	for protocol in protocols {
		registry.protocols_by_path[protocol.xml_path] = protocol
	}

	for protocol in protocols {
		for interface_name in protocol.interface_names {
			owner := Interface_Owner {
				full_interface_name = interface_name,
				protocol_name       = protocol.name,
				import_path         = protocol.import_path,
				module_name         = protocol.module_name,
				alias               = protocol.alias,
				short_name          = short_interface_name(interface_name),
				xml_path            = protocol.xml_path,
			}

			owners := registry.owners[owner.full_interface_name]
			append(&owners, owner)
			registry.owners[owner.full_interface_name] = owners
		}
	}

	sort_owners :: proc(a, b: Interface_Owner) -> slice.Ordering {
		if a.import_path != b.import_path {
			return slice.cmp(a.import_path, b.import_path)
		}
		if a.protocol_name != b.protocol_name {
			return slice.cmp(a.protocol_name, b.protocol_name)
		}
		return slice.cmp(a.xml_path, b.xml_path)
	}

	for interface_name, owners in registry.owners {
		if len(owners) <= 1 {
			continue
		}
		slice.sort_by_cmp(owners[:], sort_owners)
		registry.owners[interface_name] = owners
	}

	return registry, true
}

normalize_protocol_import_name :: proc(raw: string) -> string {
	if raw == "" {
		return ""
	}

	normalized := strings.to_lower(strings.trim_space(raw))
	if strings.contains_rune(normalized, '\\') {
		normalized, _ = strings.replace_all(normalized, "\\", "/")
	}

	last_slash := strings.last_index_byte(normalized, '/')
	if last_slash >= 0 && last_slash + 1 < len(normalized) {
		normalized = normalized[last_slash + 1:]
	}

	if strings.has_suffix(normalized, ".xml") {
		normalized = normalized[:len(normalized) - len(".xml")]
	}

	normalized, _ = strings.replace_all(normalized, "-", "_")
	normalized, _ = strings.replace_all(normalized, ".", "_")
	return normalized
}

parse_protocol_import_name :: proc(doc: ^xml.Document, id: xml.Element_ID) -> string {
	import_name := get_attribute_optional(doc, id, "name")
	if import_name != "" {
		return import_name
	}

	interface_name := get_attribute_optional(doc, id, "interface")
	if interface_name != "" {
		return interface_name
	}

	return strings.trim_space(element_text(doc, id))
}

append_unique_string :: proc(values: ^[dynamic]string, value: string) {
	if value == "" {
		return
	}
	if slice.contains(values^[:], value) {
		return
	}
	append(values, value)
}

parse_protocol_metadata_from_source :: proc(
	source: Registry_Source,
) -> (
	metadata: Protocol_Metadata,
	ok: bool,
) {
	doc, xml_err := xml.load_from_file(source.xml_path)
	if xml_err != .None {
		fmt.eprintfln("Failed to load registry XML file '%v': %v", source.xml_path, xml_err)
		return
	}
	defer xml.destroy(doc)

	if doc == nil || len(doc.elements) == 0 {
		fmt.eprintfln("Registry XML document '%v' is empty.", source.xml_path)
		return
	}

	root_id := xml.Element_ID(0)
	root := doc.elements[root_id]
	if root.kind != .Element || root.ident != "protocol" {
		fmt.eprintfln("Registry XML root must be <protocol>: %v", source.xml_path)
		return
	}

	protocol_name := get_attribute_required(doc, root_id, "name") or_return
	metadata.name, ok = clone_string_or_report(protocol_name, "protocol name")
	if !ok {
		return
	}
	metadata.xml_path, ok = clone_string_or_report(source.xml_path, "registry source path")
	if !ok {
		return
	}
	metadata.import_path, ok = clone_string_or_report(source.import_path, "registry import path")
	if !ok {
		return
	}
	module_name := import_path_leaf(source.import_path)
	metadata.module_name, ok = clone_string_or_report(module_name, "protocol module name")
	if !ok {
		return
	}

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
			case "interface":
				interface_name := get_attribute_required(doc, child_id, "name") or_return
				interface_clone, clone_ok := clone_string_or_report(
					interface_name,
					"interface name",
				)
				if !clone_ok {
					return
				}
				append(&metadata.interface_names, interface_clone)

			case "import":
				import_name := normalize_protocol_import_name(
					parse_protocol_import_name(doc, child_id),
				)
				if import_name == "" {
					continue
				}
				import_clone, clone_ok := clone_string_or_report(
					import_name,
					"imported protocol name",
				)
				if !clone_ok {
					return
				}
				append_unique_string(&metadata.imported_protocols, import_clone)
			case:
				continue
			}
		}
	}

	if len(metadata.interface_names) == 0 {
		fmt.eprintfln("Registry XML '%v' does not define any interfaces.", source.xml_path)
		return
	}

	return metadata, true
}

assign_protocol_aliases :: proc(protocols: []Protocol_Metadata) -> bool {
	sort_protocols :: proc(a, b: Protocol_Metadata) -> slice.Ordering {
		if a.import_path != b.import_path {
			return slice.cmp(a.import_path, b.import_path)
		}
		if a.name != b.name {
			return slice.cmp(a.name, b.name)
		}
		return slice.cmp(a.xml_path, b.xml_path)
	}

	slice.sort_by_cmp(protocols, sort_protocols)

	alias_to_import := make(map[string]string)
	for i in 0 ..< len(protocols) {
		candidates := protocol_alias_candidates(protocols[i])

		alias := ""
		for candidate in candidates {
			existing_import_path, exists := alias_to_import[candidate]
			if !exists || existing_import_path == protocols[i].import_path {
				alias = candidate
				break
			}
		}

		if alias == "" {
			base := sanitize_alias(trim_version_suffix(protocols[i].name))
			if base == "" {
				base = "protocol"
			}

			for suffix in 2 ..< max(int) {
				candidate := fmt.aprintf("%v_%v", base, suffix)
				existing_import_path, exists := alias_to_import[candidate]
				if !exists || existing_import_path == protocols[i].import_path {
					alias = candidate
					break
				}
			}
		}

		if alias == "" {
			fmt.eprintfln(
				"Unable to allocate import alias for registry protocol '%v' (%v).",
				protocols[i].name,
				protocols[i].xml_path,
			)
			return false
		}

		protocols[i].alias = alias
		alias_to_import[alias] = protocols[i].import_path
	}

	return true
}

protocol_alias_candidates :: proc(protocol: Protocol_Metadata) -> (candidates: [dynamic]string) {
	add_alias_candidate(&candidates, common_interface_alias(protocol.interface_names[:]))
	add_alias_candidate(&candidates, trim_version_suffix(protocol.name))
	add_alias_candidate(&candidates, import_path_leaf(protocol.import_path))
	add_alias_candidate(&candidates, protocol.name)

	base_alias := sanitize_alias(protocol.name)
	dot_index := strings.index_byte(base_alias, '_')
	if dot_index > 0 {
		add_alias_candidate(&candidates, base_alias[:dot_index])
	}

	return candidates
}

add_alias_candidate :: proc(candidates: ^[dynamic]string, raw_alias: string) {
	alias := sanitize_alias(raw_alias)
	if alias == "" || alias == "wl" {
		return
	}
	for existing in candidates^ {
		if existing == alias {
			return
		}
	}
	append(candidates, alias)
}

sanitize_alias :: proc(raw_alias: string) -> string {
	if raw_alias == "" {
		return ""
	}

	bytes: [dynamic]byte
	for ch in raw_alias {
		if ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') || ('0' <= ch && ch <= '9') {
			append(&bytes, byte(ch))
		} else {
			append(&bytes, byte('_'))
		}
	}

	if len(bytes) == 0 {
		return ""
	}

	start := 0
	for start < len(bytes) && bytes[start] == '_' {
		start += 1
	}

	end := len(bytes)
	for end > start && bytes[end - 1] == '_' {
		end -= 1
	}

	if start >= end {
		return ""
	}

	alias := string(bytes[start:end])
	if alias[0] >= '0' && alias[0] <= '9' {
		alias = fmt.aprintf("_%v", alias)
	}
	alias = strings.to_lower(alias)

	clone, clone_err := strings.clone(alias)
	if clone_err != nil {
		return alias
	}
	return clone
}

common_interface_alias :: proc(interface_names: []string) -> string {
	if len(interface_names) == 0 {
		return ""
	}

	base_tokens := split_name_tokens(interface_names[0])
	if len(base_tokens) == 0 {
		return ""
	}
	common_count := len(base_tokens)

	for interface_name in interface_names[1:] {
		interface_tokens := split_name_tokens(interface_name)
		limit := min(common_count, len(interface_tokens))

		matched := 0
		for matched < limit {
			if base_tokens[matched] != interface_tokens[matched] {
				break
			}
			matched += 1
		}

		common_count = matched
		if common_count == 0 {
			break
		}
	}

	if common_count > 0 && is_version_token(base_tokens[common_count - 1]) {
		common_count -= 1
	}
	if common_count <= 0 {
		return ""
	}

	return join_tokens(base_tokens[:common_count], "_")
}

trim_version_suffix :: proc(raw_name: string) -> string {
	tokens := split_name_tokens(raw_name)
	if len(tokens) > 1 && is_version_token(tokens[len(tokens) - 1]) {
		return join_tokens(tokens[:len(tokens) - 1], "_")
	}
	return raw_name
}

import_path_leaf :: proc(import_path: string) -> string {
	normalized := normalize_import_segment(import_path)
	last_slash := strings.last_index_byte(normalized, '/')
	if last_slash >= 0 && last_slash + 1 < len(normalized) {
		return normalized[last_slash + 1:]
	}

	last_colon := strings.last_index_byte(normalized, ':')
	if last_colon >= 0 && last_colon + 1 < len(normalized) {
		return normalized[last_colon + 1:]
	}

	return normalized
}

split_name_tokens :: proc(raw: string) -> (tokens: [dynamic]string) {
	if raw == "" {
		return
	}

	start := 0
	for i := 0; i < len(raw); i += 1 {
		if raw[i] == '_' {
			if i > start {
				append(&tokens, raw[start:i])
			}
			start = i + 1
		}
	}
	if start < len(raw) {
		append(&tokens, raw[start:])
	}
	return
}

join_tokens :: proc(tokens: []string, separator: string) -> string {
	if len(tokens) == 0 {
		return ""
	}
	if len(tokens) == 1 {
		return tokens[0]
	}

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, tokens[0])
	for token in tokens[1:] {
		strings.write_string(&sb, separator)
		strings.write_string(&sb, token)
	}
	joined := strings.to_string(sb)
	clone, clone_err := strings.clone(joined)
	if clone_err != nil {
		return joined
	}
	return clone
}

is_version_token :: proc(token: string) -> bool {
	if len(token) < 2 || token[0] != 'v' {
		return false
	}
	for ch in token[1:] {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

emit_protocol_imports :: proc(ctx: ^Emit_Context, protocol: ^Protocol) {
	if ctx.is_wayland_core {
		return
	}

	emitln(ctx, "import \"core:c\"")
	emitln(ctx, "import wl \"%v\"", protocol.wayland_import_path)

	if len(protocol.external_imports) > 0 {
		aliases: [dynamic]string
		for alias in protocol.external_imports {
			if alias == "wl" {
				continue
			}
			append(&aliases, alias)
		}

		sort_aliases :: proc(a, b: string) -> slice.Ordering {
			return slice.cmp(a, b)
		}
		slice.sort_by_cmp(aliases[:], sort_aliases)

		for alias in aliases {
			import_path := protocol.external_imports[alias]
			emitln(ctx, "import %v \"%v\"", alias, import_path)
		}
	}

	emitln(ctx)
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

	emit_protocol_imports(&ctx, protocol)

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

argument_name_for_odin :: proc(arg: ^Argument) -> string {
	if arg.name_odin != "" {
		return arg.name_odin
	}
	return sanitize_identifier(arg.name)
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
	return fmt.aprintf("%v: %v", argument_name_for_odin(arg), text)
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
						argument_name_for_odin(argument),
						argument.prefix,
						argument.interface_name_ada,
					)
				} else {
					emit(
						ctx,
						", %v: ^%vInterface, version: u32",
						argument_name_for_odin(argument),
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
				emit(ctx, ", %v: %v", argument_name_for_odin(argument), typ)
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
				emit(ctx, ", %v, version", argument_name_for_odin(request.new_id_argument))
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
						emit(ctx, ", %v.name, version, nil", argument_name_for_odin(argument))
					} else {
						emit(ctx, ", nil")
					}
				} else {
					emit(ctx, ", %v", argument_name_for_odin(argument))
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
				emit(ctx, ", %v", argument_name_for_odin(argument))
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
	argument.name_odin = sanitize_identifier(argument.name)

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

ODIN_KEYWORDS :: []string {
	"asm",
	"auto_cast",
	"bit_field",
	"bit_set",
	"break",
	"case",
	"cast",
	"context",
	"continue",
	"defer",
	"distinct",
	"do",
	"dynamic",
	"else",
	"enum",
	"fallthrough",
	"for",
	"foreign",
	"if",
	"import",
	"in",
	"map",
	"matrix",
	"not_in",
	"notin",
	"or_break",
	"or_continue",
	"or_else",
	"or_return",
	"package",
	"proc",
	"return",
	"struct",
	"switch",
	"transmute",
	"typeid",
	"union",
	"using",
	"when",
	"where",
}

short_interface_name :: proc(full_name: string) -> string {
	index := strings.index_byte(full_name, '_')
	if index <= 0 || index + 1 >= len(full_name) {
		return full_name
	}
	return full_name[index + 1:]
}

is_odin_keyword :: proc(identifier: string) -> bool {
	return slice.contains(ODIN_KEYWORDS, identifier)
}

sanitize_identifier :: proc(raw: string) -> string {
	if raw == "" {
		return "_"
	}

	bytes: [dynamic]byte
	for ch in raw {
		if ('a' <= ch && ch <= 'z') ||
		   ('A' <= ch && ch <= 'Z') ||
		   ('0' <= ch && ch <= '9') ||
		   ch == '_' {
			append(&bytes, byte(ch))
		} else {
			append(&bytes, byte('_'))
		}
	}

	if len(bytes) == 0 {
		return "_"
	}

	sanitized := string(bytes[:])
	if sanitized[0] >= '0' && sanitized[0] <= '9' {
		sanitized = fmt.aprintf("_%v", sanitized)
	}
	if is_odin_keyword(sanitized) {
		sanitized = fmt.aprintf("%v_", sanitized)
	}
	clone, clone_err := strings.clone(sanitized)
	if clone_err != nil {
		return sanitized
	}
	return clone
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

build_resolution_context :: proc(
	protocol: ^Protocol,
	registry: ^Interface_Registry,
	source_xml_path: string,
) -> Resolution_Context {
	resolution_context := Resolution_Context {
		protocol_name = protocol.name,
		module_name   = trim_version_suffix(protocol.name),
	}

	if source_xml_path == "" {
		return resolution_context
	}

	if metadata, ok := registry.protocols_by_path[source_xml_path]; ok {
		resolution_context.protocol_name = metadata.name
		resolution_context.import_path = metadata.import_path
		resolution_context.module_name = metadata.module_name
		resolution_context.imported_protocols = metadata.imported_protocols[:]
	}

	return resolution_context
}

owner_matches_import_name :: proc(owner: Interface_Owner, import_name: string) -> bool {
	if import_name == "" {
		return false
	}

	if normalize_protocol_import_name(owner.protocol_name) == import_name {
		return true
	}
	if normalize_protocol_import_name(owner.module_name) == import_name {
		return true
	}
	return false
}

filter_owners_by_imports :: proc(
	owners: []Interface_Owner,
	imported_protocols: []string,
) -> (
	filtered: [dynamic]Interface_Owner,
) {
	if len(imported_protocols) == 0 {
		return
	}

	for owner in owners {
		for imported_protocol in imported_protocols {
			if owner_matches_import_name(owner, imported_protocol) {
				append(&filtered, owner)
				break
			}
		}
	}

	return
}

filter_owners_by_protocol :: proc(
	owners: []Interface_Owner,
	protocol_name: string,
) -> (
	filtered: [dynamic]Interface_Owner,
) {
	target := normalize_protocol_import_name(protocol_name)
	if target == "" {
		return
	}

	for owner in owners {
		if normalize_protocol_import_name(owner.protocol_name) == target {
			append(&filtered, owner)
		}
	}
	return
}

filter_owners_by_module :: proc(
	owners: []Interface_Owner,
	module_name: string,
) -> (
	filtered: [dynamic]Interface_Owner,
) {
	target := normalize_protocol_import_name(module_name)
	if target == "" {
		return
	}

	for owner in owners {
		if normalize_protocol_import_name(owner.module_name) == target {
			append(&filtered, owner)
		}
	}
	return
}

is_protocol_variant_name :: proc(protocol_name: string) -> bool {
	normalized := normalize_protocol_import_name(protocol_name)
	return strings.contains(normalized, "_unstable_") || strings.contains(normalized, "_staging_")
}

filter_owners_by_canonical_protocol :: proc(
	owners: []Interface_Owner,
) -> (
	filtered: [dynamic]Interface_Owner,
) {
	for owner in owners {
		if !is_protocol_variant_name(owner.protocol_name) {
			append(&filtered, owner)
		}
	}
	return
}

resolve_external_candidates :: proc(
	registry: ^Interface_Registry,
	resolution: ^Resolution_Context,
	interface_name: string,
) -> []Interface_Owner {
	owners, found := registry.owners[interface_name]
	if !found || len(owners) == 0 {
		return nil
	}

	candidates := owners[:]
	if len(candidates) <= 1 {
		return candidates
	}

	import_candidates := filter_owners_by_imports(candidates, resolution.imported_protocols)
	if len(import_candidates) == 1 {
		return import_candidates[:]
	}
	if len(import_candidates) > 1 {
		candidates = import_candidates[:]
	}

	protocol_candidates := filter_owners_by_protocol(candidates, resolution.protocol_name)
	if len(protocol_candidates) == 1 {
		return protocol_candidates[:]
	}
	if len(protocol_candidates) > 1 {
		candidates = protocol_candidates[:]
	}

	module_candidates := filter_owners_by_module(candidates, resolution.module_name)
	if len(module_candidates) == 1 {
		return module_candidates[:]
	}
	if len(module_candidates) > 1 {
		candidates = module_candidates[:]
	}

	canonical_candidates := filter_owners_by_canonical_protocol(candidates)
	if len(canonical_candidates) == 1 {
		return canonical_candidates[:]
	}
	if len(canonical_candidates) > 1 {
		candidates = canonical_candidates[:]
	}

	return candidates
}

resolve_interface_reference :: proc(
	protocol: ^Protocol,
	registry: ^Interface_Registry,
	resolution: ^Resolution_Context,
	source: Reference_Source,
	required_imports: ^map[string]string,
	interface_name: string,
) -> (
	prefix, short_name: string,
	ok: bool,
) {
	target := find_interface_by_full_name(protocol, interface_name)
	if target != nil {
		return "", target.name, true
	}

	if strings.has_prefix(interface_name, "wl_") {
		return "wl.", short_interface_name(interface_name), true
	}

	candidates := resolve_external_candidates(registry, resolution, interface_name)
	if len(candidates) == 0 {
		report_unresolved_interface_reference(source)
		return "", "", false
	}

	if len(candidates) > 1 {
		report_ambiguous_interface_reference(source, candidates)
		return "", "", false
	}

	owner := candidates[0]
	if owner.import_path == "" {
		fmt.eprintfln(
			"Interface '%v' is known from '%v' but has no import path. Registry source XML path could not be mapped to an Odin package path.",
			interface_name,
			owner.xml_path,
		)
		return "", "", false
	}

	import_path, import_ok := relative_import_path(resolution.import_path, owner.import_path)
	if !import_ok {
		return "", "", false
	}

	record_external_import(required_imports, owner.alias, import_path, source) or_return
	return fmt.aprintf("%v.", owner.alias), owner.short_name, true
}

resolve_enumeration_reference :: proc(
	protocol: ^Protocol,
	current_interface: ^Interface,
	enum_reference: string,
	registry: ^Interface_Registry,
	resolution: ^Resolution_Context,
	required_imports: ^map[string]string,
	source: Reference_Source,
) -> (
	prefix: string,
	resolved_name: string,
	bitfield, found: bool,
	ok: bool,
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
					false,
					true
			}

			external_source := source
			external_source.referenced_interface = target_interface_name

			candidates := resolve_external_candidates(registry, resolution, target_interface_name)
			if len(candidates) == 0 {
				report_unresolved_enum_reference(source, enum_reference, target_interface_name)
				return "", "", false, false, false
			}
			if len(candidates) > 1 {
				report_ambiguous_enum_reference(
					source,
					enum_reference,
					target_interface_name,
					candidates,
				)
				return "", "", false, false, false
			}

			owner := candidates[0]
			if owner.import_path == "" {
				fmt.eprintfln(
					"Enumeration '%v' references interface '%v' from '%v', but that protocol has no import path mapping.",
					enum_reference,
					target_interface_name,
					owner.xml_path,
				)
				return "", "", false, false, false
			}

			import_path, import_ok := relative_import_path(
				resolution.import_path,
				owner.import_path,
			)
			if !import_ok {
				return "", "", false, false, false
			}

			record_external_import(
				required_imports,
				owner.alias,
				import_path,
				external_source,
			) or_return

			return fmt.aprintf("%v.", owner.alias),
				fmt.aprintf("%v_%v", owner.short_name, enum_name),
				false,
				false,
				true
		}

		resolved_name = fmt.aprintf("%v_%v", target_interface.name, enum_name)
		enumeration := find_enumeration_by_name(target_interface, enum_name)
		if enumeration != nil {
			return "", resolved_name, enumeration.bitfield, true, true
		}
		return "", resolved_name, false, false, true
	}

	resolved_name = fmt.aprintf("%v_%v", current_interface.name, enum_reference)
	enumeration := find_enumeration_by_name(current_interface, enum_reference)
	if enumeration != nil {
		return "", resolved_name, enumeration.bitfield, true, true
	}
	return "", resolved_name, false, false, true
}

record_external_import :: proc(
	required_imports: ^map[string]string,
	alias: string,
	import_path: string,
	source: Reference_Source,
) -> bool {
	if alias == "" || import_path == "" {
		return true
	}

	if existing_path, exists := required_imports^[alias]; exists && existing_path != import_path {
		fmt.eprintfln(
			"Import alias collision for '%v': '%v' vs '%v' while resolving '%v' in %v.%v.%v(%v).",
			alias,
			existing_path,
			import_path,
			source.referenced_interface,
			source.protocol_name,
			source.interface_full_name,
			source.message_name,
			source.argument_name,
		)
		return false
	}

	required_imports^[alias] = import_path
	return true
}

report_unresolved_interface_reference :: proc(source: Reference_Source) {
	fmt.eprintfln(
		"Unresolved interface reference '%v' in protocol='%v', interface='%v', message='%v', argument='%v'. Ensure -wayland-xml and -protocols-dir include the defining XML.",
		source.referenced_interface,
		source.protocol_name,
		source.interface_full_name,
		source.message_name,
		source.argument_name,
	)
}

report_ambiguous_interface_reference :: proc(
	source: Reference_Source,
	candidates: []Interface_Owner,
) {
	fmt.eprintfln(
		"Ambiguous interface reference '%v' in protocol='%v', interface='%v', message='%v', argument='%v'. Add explicit <import> in XML or reduce registry inputs. Candidates:",
		source.referenced_interface,
		source.protocol_name,
		source.interface_full_name,
		source.message_name,
		source.argument_name,
	)
	for owner in candidates {
		fmt.eprintfln(
			"  - protocol='%v' module='%v' import='%v' xml='%v'",
			owner.protocol_name,
			owner.module_name,
			owner.import_path,
			owner.xml_path,
		)
	}
}

report_unresolved_enum_reference :: proc(
	source: Reference_Source,
	enum_reference: string,
	target_interface_name: string,
) {
	fmt.eprintfln(
		"Unresolved enum interface '%v' from enum='%v' in protocol='%v', interface='%v', message='%v', argument='%v'. Ensure -wayland-xml and -protocols-dir include the defining XML.",
		target_interface_name,
		enum_reference,
		source.protocol_name,
		source.interface_full_name,
		source.message_name,
		source.argument_name,
	)
}

report_ambiguous_enum_reference :: proc(
	source: Reference_Source,
	enum_reference: string,
	target_interface_name: string,
	candidates: []Interface_Owner,
) {
	fmt.eprintfln(
		"Ambiguous enum interface '%v' from enum='%v' in protocol='%v', interface='%v', message='%v', argument='%v'. Candidates:",
		target_interface_name,
		enum_reference,
		source.protocol_name,
		source.interface_full_name,
		source.message_name,
		source.argument_name,
	)
	for owner in candidates {
		fmt.eprintfln(
			"  - protocol='%v' module='%v' import='%v' xml='%v'",
			owner.protocol_name,
			owner.module_name,
			owner.import_path,
			owner.xml_path,
		)
	}
}

normalize_argument_names :: proc(message: ^Message) {
	used := make(map[string]bool)

	for argument in message.arguments {
		base := argument.name_odin
		if base == "" {
			base = sanitize_identifier(argument.name)
		}

		candidate := base
		if used[candidate] {
			for suffix in 2 ..< max(int) {
				next := fmt.aprintf("%v_%v", base, suffix)
				if !used[next] {
					candidate = next
					break
				}
			}
		}

		argument.name_odin = candidate
		used[candidate] = true
	}
}

normalize_argument :: proc(
	protocol: ^Protocol,
	interface: ^Interface,
	message: ^Message,
	argument: ^Argument,
	registry: ^Interface_Registry,
	resolution: ^Resolution_Context,
	required_imports: ^map[string]string,
) -> (
	ok: bool,
) {
	if argument.interface_name != "" {
		source := Reference_Source {
			protocol_name        = protocol.name,
			interface_full_name  = interface.full_name,
			message_name         = message.name,
			argument_name        = argument.name,
			referenced_interface = argument.interface_name,
		}

		argument.prefix, argument.interface_name, ok = resolve_interface_reference(
			protocol,
			registry,
			resolution,
			source,
			required_imports,
			argument.interface_name,
		)
		if !ok {
			return false
		}
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

	source := Reference_Source {
		protocol_name        = protocol.name,
		interface_full_name  = interface.full_name,
		message_name         = message.name,
		argument_name        = argument.name,
		referenced_interface = argument.enumeration_name,
	}

	enum_prefix, resolved_name, bitfield, found, resolved_ok := resolve_enumeration_reference(
		protocol,
		interface,
		argument.enumeration_name,
		registry,
		resolution,
		required_imports,
		source,
	)
	if !resolved_ok {
		return false
	}

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
	registry: ^Interface_Registry,
	resolution: ^Resolution_Context,
	required_imports: ^map[string]string,
) -> (
	ok: bool,
) {
	normalize_argument_names(message)
	message.all_null = true

	if message.return_argument != nil {
		normalize_argument(
			protocol,
			interface,
			message,
			message.return_argument,
			registry,
			resolution,
			required_imports,
		) or_return
		if message.return_argument.interface_name != "" {
			message.all_null = false
		}
	}

	for argument in message.arguments {
		normalize_argument(
			protocol,
			interface,
			message,
			argument,
			registry,
			resolution,
			required_imports,
		) or_return

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

finalize_protocol :: proc(
	protocol: ^Protocol,
	registry: ^Interface_Registry,
	source_xml_path: string,
) -> bool {
	protocol.null_run_length = 0
	protocol.type_index_counter = 0
	protocol.external_imports = make(map[string]string)
	resolution := build_resolution_context(protocol, registry, source_xml_path)
	if protocol.name == "wayland" {
		protocol.wayland_import_path = "."
	} else {
		wayland_import_path, wayland_ok := relative_import_path(resolution.import_path, "")
		if !wayland_ok {
			return false
		}
		protocol.wayland_import_path = wayland_import_path
	}

	for interface in protocol.interfaces {
		for request in interface.requests {
			normalize_message(
				protocol,
				interface,
				request,
				registry,
				&resolution,
				&protocol.external_imports,
			) or_return
		}
		for event in interface.events {
			normalize_message(
				protocol,
				interface,
				event,
				registry,
				&resolution,
				&protocol.external_imports,
			) or_return
		}
	}

	return true
}
